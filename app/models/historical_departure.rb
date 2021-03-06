class HistoricalDeparture < ApplicationRecord

  include FastInsert
  include PreventDuplicates

  DAYS_OF_WEEK = {
    sunday: 0,
    monday: 1,
    tuesday: 2,
    wednesday: 3,
    thursday: 4,
    friday: 5,
    saturday: 6,
  }

  belongs_to :bus_stop
  belongs_to :previous_departure, class_name: "HistoricalDeparture", required: false
  validates :headway, numericality: {greater_than: 0, allow_nil: true}

  scope :newer_than, -> (num) { where(["departure_time > ?", num.seconds.ago]) }
  scope :older_than, -> (num) { where(["departure_time < ?", num.seconds.ago]) }
  scope :interpolated, -> { where(interpolated: true) }
  scope :actual, -> { where(interpolated: false) }

  # Additional scopes

  def self.for_route_and_stop(line_ref, stop_ref)
    self.where(line_ref: line_ref, stop_ref: stop_ref).order(departure_time: :desc)
  end

  def self.between_hours(start_hour_in_est, end_hour_in_est)
    # departure_time is stored in Postgres as timestamp without time zone
    # departure_time AT TIME ZONE 'UTC' gives it a time zone UTC
    # So we can then convert that to EST and extract the hour of the day
    # Hour is 0-23.
    self.where(["extract(hour from (departure_time AT TIME ZONE 'UTC') AT TIME ZONE 'EST') > ? AND extract(hour from (departure_time AT TIME ZONE 'UTC') AT TIME ZONE 'EST') < ?", start_hour_in_est - 1, end_hour_in_est])
  end

  def self.morning_rush_hours_only
    # 6am - 10am Mon-Fri
    self.weekdays_only.between_hours(7, 9)
  end

  def self.evening_rush_hours_only
    self.weekdays_only.between_hours(16, 19)
  end

  def self.on_day_of_week(day_sym)
    # Convert departure_time to EST
    # Return only records from that day of the week
    day_num = DAYS_OF_WEEK[day_sym.to_sym]
    self.where(["extract(dow from (departure_time AT TIME ZONE 'UTC') AT TIME ZONE 'EST') = ?", day_num])
  end

  def self.weekdays_only
    self.where(["extract(dow from (departure_time AT TIME ZONE 'UTC') AT TIME ZONE 'EST') > ? AND extract(dow from (departure_time AT TIME ZONE 'UTC') AT TIME ZONE 'EST') < ?", DAYS_OF_WEEK[:sunday], DAYS_OF_WEEK[:saturday]])
  end

  def self.weekends_only
    self.where(["extract(dow from (departure_time AT TIME ZONE 'UTC') AT TIME ZONE 'EST') = ? OR extract(dow from (departure_time AT TIME ZONE 'UTC') AT TIME ZONE 'EST') = ?", DAYS_OF_WEEK[:saturday], DAYS_OF_WEEK[:sunday]])
  end

  # BusRate Score methods

  def self.rating(departures, allowable_headway_in_minutes, current_headway = nil)
    Rating.new(departures, allowable_headway_in_minutes, current_headway).score
  end

  def self.recent_rating_for_route_and_stop(line_ref, stop_ref, allowable_headway = 8, age_in_secs = 14_400)
    departures = HistoricalDeparture.for_route_and_stop(line_ref, stop_ref).newer_than(age_in_secs)
    self.rating(departures, allowable_headway)
  end

  def self.recent_rating_for_route(line_ref, direction_ref = nil, allowable_headway = 8, age_in_secs = 14_400)
    departures = HistoricalDeparture.newer_than(age_in_secs).where(line_ref: line_ref)
    if direction_ref
      departures = departures.where(direction_ref: direction_ref)
    end
    self.rating(departures, allowable_headway)
  end

  # Data creation methods

  def self.is_departure?(old_vehicle_position, new_vehicle_position)
    return false if old_vehicle_position.blank? || new_vehicle_position.blank?
    # If all of the following rules apply, we consider it a departure:
    # timestamp for new_vehicle_position is after old_vehicle_position
    # vehicle_ref is the same
    # direction_ref is the same
    # arrival_text for old_vehicle_position is 'at stop', 'approaching', or '< 1 stop away'
    # the two vehicle positions are less than 90 seconds apart
    # stop_ref changes
    # TODO: stop_ref changes to the NEXT stop on the route (not just any stop)

    return false unless new_vehicle_position.timestamp > old_vehicle_position.timestamp
    return false unless new_vehicle_position.vehicle_ref == old_vehicle_position.vehicle_ref
    return false unless new_vehicle_position.direction_ref == old_vehicle_position.direction_ref
    return false unless (new_vehicle_position.timestamp - old_vehicle_position.timestamp) < 90.seconds
    return false unless ["at stop", "approaching", "< 1 stop away"].include?(old_vehicle_position.arrival_text)
    return false unless new_vehicle_position.stop_ref != old_vehicle_position.stop_ref

    true
  end

  def self.expired_dep?(old_vp, new_vp)
    if new_vp.timestamp - old_vp.timestamp > 90.seconds &&
      new_vp.vehicle_ref == old_vp.vehicle_ref &&
      ["at stop", "approaching", "< 1 stop away"].include?(old_vp.arrival_text) &&
      new_vp.stop_ref != old_vp.stop_ref
      return true
    end
    false
  end

  def self.scrape_all
    # Before scraping, remove duplicate VehiclePositions to try to prevent creating duplicate departures
    # logger.info "Purging duplicate VehiclePositions < 4 minutes old"
    existing_count = VehiclePosition.newer_than(240).count
    VehiclePosition.purge_duplicates_newer_than(240)
    purge_count = existing_count - VehiclePosition.newer_than(240).count
    logger.info "Purged #{purge_count} duplicate VehiclePositions" unless purge_count == 0

    self.scrape_from(VehiclePosition.newer_than(240))
  end

  def self.scrape_from(vehicle_positions)
    # Take a list of vehicle_positions, compare them, and create departures
    start_time = Time.current
    logger = Logger.new('log/grab.log')
    identifier = start_time.to_f.to_s.split(".")[1].first(4)
    logger.info "Starting departure scrape # #{identifier} at #{start_time.in_time_zone("EST")}"

    departures = []

    vehicle_positions = vehicle_positions.group_by(&:vehicle_ref)
    # "MTABC_3742"=>[#<VehiclePosition ...>, #<VehiclePosition ...>, #<VehiclePosition ...>]
    # logger.info "Filtering #{vehicle_positions.length} VehiclePositions"
    vehicle_positions.delete_if { |k, v| v.length < 2 }
    # logger.info "Filtered to #{vehicle_positions.length} vehicles with 2+ positions"
    ids_to_purge = []
    expired_count = 0
    addl_count = 0
    dup_count = 0
    vehicle_positions.each do |veh_ref, vp_list|
      sorted_vps = vp_list.sort_by(&:timestamp) # guarantee that the oldest vehicle_position is first

      while sorted_vps.length > 1 do
        # Remove the oldest vehicle position
        old_vehicle_position = sorted_vps.shift

        # Compare it with every other position to see if we can make a departure
        sorted_vps.each do |new_vehicle_position|
          # expired_count += 1 if expired_dep?(old_vehicle_position, new_vehicle_position)
          if VehiclePosition.is_duplicate?(old_vehicle_position, new_vehicle_position)
            new_vehicle_position.delete
            dup_count += 1
            next
          end
          if is_departure?(old_vehicle_position, new_vehicle_position)
            addl_count += 1 if old_vehicle_position.arrival_text != "at stop"
            bus_stop = BusStop.find_or_create_by(stop_ref: old_vehicle_position.stop_ref)
            logger.error "bus_stop not found: #{new_vehicle_position.stop_ref}" if bus_stop.blank?
            next unless bus_stop.present?
            new_departure = {
              bus_stop_id: bus_stop.id,
              stop_ref: old_vehicle_position.stop_ref,
              line_ref: new_vehicle_position.line_ref,
              direction_ref: new_vehicle_position.direction_ref,
              vehicle_ref: new_vehicle_position.vehicle_ref,
              block_ref: new_vehicle_position.block_ref,
              dated_vehicle_journey_ref: new_vehicle_position.dated_vehicle_journey_ref,
              departure_time: new_vehicle_position.timestamp - 30.seconds, # TODO: see if we still need this 30 seconds
              interpolated: false,
            }
            # Purge the old_vehicle positions so they can't be used in the future to make duplicate departures
            ids_to_purge << old_vehicle_position.id
            departures << new_departure

            break # don't make any additional departures from these two vehicle_positions
          end
        end
      end
    end

    ids_to_purge.uniq!

    departure_object_list = self.prevent_duplicates(departures.compact.uniq, HistoricalDeparture.newer_than(1_200).reload)

    fast_insert_objects(departure_object_list)
    VehiclePosition.delete(ids_to_purge.take(65_535))

    logger.info "!------------- #{departure_object_list.length} historical departures created -------------!"
    logger.info "Avoided #{departures.compact.length - departures.compact.uniq.length} duplicate departures by removing non-unique values"
    logger.info "Avoided #{dup_count} duplicate departures by destroying duplicate vehicle positions" if dup_count > 0
    # logger.info "#{expired_count} departures not created because vehicle positions were > 90 seconds apart" unless expired_count == 0
    logger.info "#{ids_to_purge.length} old vehicle positions purged"
    logger.info "Departure scrape # #{identifier} complete in #{(Time.current - start_time).round(2)} seconds"

  end

  def self.tracking_key(dep)
    "#{approximate_timestamp(dep["departure_time"])} #{dep["vehicle_ref"]} #{dep["stop_ref"]}"
  end

  def self.approximate_timestamp(time)
    # Returns an integer timestamp with a precision of 10 minutes.
    basis_time = time.to_i
    basis_time - (basis_time % 600)
  end

  def self.count_duplicates
    sql = <<~HEREDOC
      SELECT COUNT(*) from historical_departures T1, historical_departures T2
      WHERE T1.id < T2.id
      AND T1.departure_time = T2.departure_time
      AND T1.stop_ref = T2.stop_ref
      AND T1.vehicle_ref = T2.vehicle_ref
      ;
    HEREDOC
    ActiveRecord::Base.connection.execute(sql).first
  end

  def self.purge_duplicates_newer_than(age_in_secs)
    min_id = HistoricalDeparture.newer_than(age_in_secs).order(created_at: :asc).ids.first
    logger.info "Purging duplicate HistoricalDepartures with id > #{min_id}"
    start_time = Time.current
    sql = <<~HEREDOC
      DELETE FROM historical_departures T1
      USING historical_departures T2
      WHERE T1.id > T2.id
      AND T1.departure_time = T2.departure_time
      AND T1.stop_ref = T2.stop_ref
      AND T1.vehicle_ref = T2.vehicle_ref
      AND T1.id > #{min_id}
      ;
    HEREDOC
    result = ActiveRecord::Base.connection.execute(sql)
    logger.info result.first
    logger.info "HistoricalDeparture.purge_duplicates_newer_than complete after #{(Time.current - start_time).round(2)} seconds"
  end

  def self.update_count
    # Update the estimated historical_departures count for the stats API endpoint
    start_time = Time.current
    logger.info "Starting ANALYZE; ..."
    ActiveRecord::Base.connection.execute("ANALYZE;")
    logger.info "ANALYZE complete in #{(Time.current - start_time).round(2)} seconds"
  rescue => err
    logger.error err
    false
  end

  def self.doit(age_in_secs, skip_non_nils = true, block_size = 2000)
    # convenience method for playing around in rails console
    hds = HistoricalDeparture.newer_than(age_in_secs)
    HistoricalDeparture.calculate_headways(hds, skip_non_nils, block_size)
  end

  def self.calculate_headways(unsorted_historical_departures, skip_non_nils = true, block_size = 2000)
    length = unsorted_historical_departures.count
    return if unsorted_historical_departures.blank? || length < 2
    start_time = Time.current
    batch_count = 0
    error_count = 0
    successful_count = 0
    non_nils_skipped = 0
    total_count = 0
    batch_elapsed_time = 0
    update_time = 0
    interp_recalcs = 0
    # 2 hours worth of historical_departures is typically 180,000+ records.
    # Here we're using the postgresql_cursor gem (each_row and each_instance methods)
    # to process all of them, hopefully without running out of memory or getting the process killed.
    HistoricalDeparture.lock.transaction do
      logger.info "Adding headways to #{length} departures..."

      current_batch = []
      current_batch_stop_ref = nil
      current_batch_line_ref = nil

      unsorted_historical_departures.order("stop_ref, line_ref, departure_time DESC").each_instance(block_size: block_size) do |current_departure|
        if current_batch_stop_ref.blank?
          # we are at the beginning of a new batch
          current_batch_stop_ref = current_departure.stop_ref
          current_batch_line_ref = current_departure.line_ref
        end
        if current_departure.stop_ref == current_batch_stop_ref && current_departure.line_ref == current_batch_line_ref
          # Add departures to current_batch until stop_ref and line_ref no longer match
          current_batch << current_departure
          next
        else
          # Process batch and update stats
          batch_result = process_batch(current_batch, skip_non_nils)
          total_count += current_batch.length
          batch_count += batch_result[:batch_count]
          error_count += batch_result[:error_count]
          successful_count += batch_result[:successful_count]
          non_nils_skipped += batch_result[:non_nils_skipped]
          batch_elapsed_time += batch_result[:elapsed_time]
          update_time += batch_result[:update_time]
          interp_recalcs += batch_result[:interp_recalcs]

          # check time limit
          if (Time.current - start_time) > 300
            logger.warn "calculate_headways took > 300 seconds; aborting"
            break
          end
          print "total_count: #{total_count} | successful_count: #{successful_count} | current batch length: #{current_batch.length} \r"
          if (total_count % 2000) < current_batch.length
            print "Doing garbage collection...                                                                                \r"
            GC.start
          end

          # clear out our workspace for the next batch
          current_batch = []
          current_batch_stop_ref = nil
          current_batch_line_ref = nil
          next
        end # if
      end # of cursor block
    end # of transaction

    puts   # Uncomment this in tandem with the print on line 391
    logger.info "#{skip_non_nils ? 'Updated' : 'Updated & overwrote'} #{successful_count} headways."
    logger.info "Processed #{batch_count} stop_ref/line_ref combinations"
    logger.info "Skipped #{non_nils_skipped} headways that were already present" if skip_non_nils
    logger.info "Recalculated #{interp_recalcs} headways to account for new interpolated departures"
    logger.info "Update failed for #{error_count} headways" if error_count > 0
    logger.info "Total headways processed: #{successful_count + batch_count + non_nils_skipped + error_count}"
    logger.info "calculate_headways done after #{(Time.current - start_time).round(2)} seconds"
    # logger.info "Including #{batch_elapsed_time.round(2)} seconds batch process time; which includes #{update_time.round(2)} seconds update time"
  end

  def self.process_batch(departure_arr, skip_non_nils = true)
    # Add headways to a list of pre-sorted departures
    # Assume departure_arr is sorted by departure_time desc
    # Assume all departures in departure_arr have the same stop_ref and line_ref

    start_time = Time.current
    update_time = 0.0
    last_index = departure_arr.length - 1
    batch_count = 1
    error_count = 0
    successful_count = 0
    non_nils_skipped = 0
    interp_recalcs = 0
    destroyed_departure = nil

    # If this batch includes any new interpolated departures, all headways must be recalculated
    if departure_arr.any? { |dep| dep.interpolated && dep.headway.nil? }
      skip_non_nils = false
      interp_recalcs = departure_arr.length
    end

    departure_arr.each_with_index do |current_departure, idx|
      # Compare each departure time with the next departure
      # The headway is the number of seconds between them
      next if idx == last_index
      if destroyed_departure
        # current_departure is the ruby instance of the destroyed departure; skip it!
        destroyed_departure = nil
        next
      end
      if skip_non_nils && current_departure.headway.present?
        non_nils_skipped += 1
        next # thank u
      end
      previous_departure = departure_arr[idx + 1]
      if current_departure.vehicle_ref == previous_departure.vehicle_ref && (current_departure.departure_time - previous_departure.departure_time) < 10.minutes
        # we have a duplicate departure; eliminate it
        destroyed_departure = previous_departure.destroy
        logger.info "process_batch: Destroying duplicate departure #{destroyed_departure.id}, vehicle_ref #{destroyed_departure.vehicle_ref}, #{destroyed_departure.departure_time}"
        logger.info "Was a duplicate of #{current_departure.id}, vehicle_ref #{current_departure.vehicle_ref}, #{current_departure.departure_time}"
        # make sure we get the headway correct
        previous_departure = departure_arr[idx + 2]
      end
      next if previous_departure.blank? # handle edge case two lines above

      headway = (current_departure.departure_time - previous_departure.departure_time).round.to_i
      # If headway rounds to 0, another vehicle left the stop the same second
      # and we don't want that to affect the average headway for the stop
      # Therefore, we don't allow a headway of 0.
      headway = nil if headway == 0
      previous_departure_id = previous_departure.id

      update_start_time = Time.current
      current_departure.update_columns(
        headway: headway,
        previous_departure_id: previous_departure_id,
      )
      update_time += (Time.current - update_start_time)

      if current_departure.errors.any?
        logger.info "Problem updating departure #{current_departure.id}: #{current_departure.errors.full_messages.join("; ")}"
        error_count += 1
      else
        successful_count += 1
      end # if
    end # of each_with_index

    {
      batch_count: batch_count,
      error_count: error_count,
      successful_count: successful_count,
      non_nils_skipped: non_nils_skipped,
      interp_recalcs: interp_recalcs,
      elapsed_time: Time.current - start_time,
      update_time: update_time,
    }
  end # of process_batch

  def self.chunk_headways
    # Take all headways less than 4 hours old
    # Divide them into 1 hour chunks and process.
    # Any headways we miss here will be taken care of just in time in the HistoricalDepartures controller.
    # 4 hrs: 14_400 seconds
    # 3.5 hrs: 13_200
    # 3 hrs: 10_800
    # 2.5 hrs: 9_000
    # 2 hrs: 7_200
    # 90 min: 5_400
    # 1 hr: 3_600

    start_time = Time.current
    logger.info "Chunking headways..."
    chunk1 = HistoricalDeparture.newer_than(14_400).older_than(10_800) # 4 - 3 hrs
    chunk2 = HistoricalDeparture.newer_than(10_801).older_than(7_200) # 3 - 2 hrs
    chunk3 = HistoricalDeparture.newer_than(7_201).older_than(3_600) # 2 - 1 hr
    chunk4 = HistoricalDeparture.newer_than(13_200).older_than(9_000) # 3.5 - 2.5 hrs
    chunk5 = HistoricalDeparture.newer_than(9_001).older_than(5_400) # 2.5 - 1.5 hrs
    chunk6 = HistoricalDeparture.newer_than(5_401).older_than(1_800) # 1.5 - 0.5 hrs
    logger.info "DB queries complete after #{(Time.current - start_time).round(2)} seconds"

    [chunk1, chunk2, chunk3, chunk4, chunk5, chunk6].each_with_index do |chunk, idx|
      logger.info "Processing chunk #{idx + 1}"
      calculate_headways(chunk)
    end
    logger.info "chunking complete after #{(Time.current - start_time).round(2)} seconds"
    # calculate_headways(HistoricalDeparture.newer_than(14_400))
    logger.info "chunk_headways complete after #{(Time.current - start_time).round(2)} seconds"
  end

  def self.is_duplicate?(dep_a, dep_b)
    if dep_a.departure_time == dep_b.departure_time &&
      dep_a.vehicle_ref == dep_b.vehicle_ref &&
      dep_a.stop_ref == dep_b.stop_ref
      return true
    end
    false
  end

  def self.timestamp_close_enough?(timestamp_a, timestamp_b)
    # If the same vehicle departs the same stop within 5 minutes, it's considered
    # close enough to be a duplicate departure
    return true if (timestamp_a - timestamp_b).abs < 5.minutes
    false
  end

  # Interpolated departures methods

  def self.for_line_and_trip(line_ref, trip_identifier)
    HistoricalDeparture.where(
      ["block_ref = ? OR dated_vehicle_journey_ref = ?", trip_identifier, trip_identifier]
    ).where(line_ref: line_ref).order(created_at: :desc, stop_ref: :desc, vehicle_ref: :desc)
  end

  def self.for_trip(trip_identifier)
    HistoricalDeparture.where(
      ["block_ref = ? OR dated_vehicle_journey_ref = ?", trip_identifier, trip_identifier]
    ).order(created_at: :desc, stop_ref: :desc, vehicle_ref: :desc)
  end

  def self.interpolate_for_route_and_stop(line_ref, stop_ref)
    # Get the ordered stop list for a bus line, pick a trip and direction, and interpolate any missing departures.
    start_time = Time.current
    logger.info "interpolate_for_route_and_stop starting: #{line_ref} #{stop_ref}"
    result = []
    # Get trip identifier and vehicle_ref
    key_departure = self.for_route_and_stop(line_ref, stop_ref).limit(8).last
    trip_identifier = key_departure.trip_identifier
    vehicle_ref = key_departure.vehicle_ref
    direction_ref = key_departure.direction_ref
    logger.info "making trip view"
    # Make trip view
    trip_view = BusLine.trip_view(trip_identifier, line_ref, vehicle_ref, direction_ref)
    # Make trip sequence
    logger.info "making trip sequences"
    trip_sequences = BusLine.all_trip_sequences(trip_view)
    logger.info "interpolating sequence"
    # Interpolate sequence
    return if trip_sequences.blank?
    interpolated_trip_sequences = trip_sequences.map { |ts| BusLine.interpolate_trip_sequence(ts) }
    logger.info "Creating departures..."
    # Make HistoricalDepartures based on results
    interpolated_trip_sequences.each do |interpolated_trip_sequence|
      new_departures_list = BusLine.interpolated_departures_to_create(interpolated_trip_sequence)
      new_departures_list.each do |dep_object|
        new_departure = HistoricalDeparture.create(dep_object)
        if new_departure.errors.any?
          result << new_departure.errors.full_messages.join("; ")
        else
          result << new_departure
        end # if
      end # each
    end # each
    logger.info "Processing headways for interpolated departures"
    stop_refs_to_update = result.select { |elem| elem.class != String }
    stop_refs_to_update.each do |dep|
      print "Processing headways for #{dep.stop_ref}...  \r"
      # Recalculate & overwrite all headways in order to incorporate the interpolated departure
      self.process_batch(self.for_route_and_stop(line_ref, dep.stop_ref).limit(8).reload, false)
    end
    logger.info "Created #{stop_refs_to_update.length} interpolated departures"
    logger.info "interpolate_for_route_and_stop complete in #{(Time.current - start_time).round(2)} seconds"
    result
  end

  def self.interpolate_recent(age_in_secs)
    start_time = Time.current
    # Take recent HistoricalDepartures and interpolate any that were missed.
    logger.info "HistoricalDeparture.interpolate_recent starting..."
    recent_departures = HistoricalDeparture.newer_than(age_in_secs)
    # make aggregate_trip_view
    logger.info "Making aggregate_trip_view"
    aggregate_trip_view = BusLine.aggregate_trip_view(recent_departures)
    # make a flat list of trip sequences
    logger.info "Making trip sequences"
    trip_sequences = []
    aggregate_trip_view.each do |trip_view|
      # print "#{trip_view[:trip_identifier]}      \r"
      trip_sequences_to_add = BusLine.all_trip_sequences(trip_view)
      next if trip_sequences_to_add.blank?
      trip_sequences_to_add.each { |ts| trip_sequences << ts }
    end
    logger.info "Interpolating trip sequences"
    interpolated_trip_sequences = trip_sequences.map do |trip_sequence|
      BusLine.interpolate_trip_sequence(trip_sequence)
    end
    puts
    logger.info "Making interpolated departure objects"
    departures_to_create = interpolated_trip_sequences.map do |its|
      BusLine.interpolated_departures_to_create(its)
    end.flatten.compact
    logger.info "interpolate_recent: preventing duplicates"
    unique_departures_to_create = self.prevent_duplicates(departures_to_create, recent_departures)
    logger.info "#{unique_departures_to_create.length} interpolated departure objects complete after #{(Time.current - start_time).round(2)} seconds"
    logger.info "Creating #{unique_departures_to_create.length} interpolated departures"
    fast_insert_objects(unique_departures_to_create)
    logger.info "interpolate_recent complete in #{(Time.current - start_time).round(2)} seconds"
  end

  # Instance methods

  def headway_in_minutes
    return nil if self.headway.blank?
    (self.headway / 60).round
  end

  def trip_identifier
    if self.block_ref
      return self.block_ref
    elsif self.dated_vehicle_journey_ref
      return self.dated_vehicle_journey_ref
    else
      nil
    end
  end



end
