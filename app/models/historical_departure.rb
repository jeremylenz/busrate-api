class HistoricalDeparture < ApplicationRecord

  belongs_to :bus_stop
  belongs_to :previous_departure, class_name: "HistoricalDeparture", allow_nil: true
  validates :headway, numericality: {greater_than: 0, allow_nil: true}

  scope :newer_than, -> (num) { where(["departure_time > ?", num.seconds.ago]) }

  def self.for_route_and_stop(line_ref, stop_ref)
    self.where(line_ref: line_ref, stop_ref: stop_ref).order(departure_time: :desc)
  end

  def self.fast_insert_objects(table_name, object_list)
    # Use the fast_inserter gem to write hundreds of rows to the table
    # with a single SQL statement.  (Active Record is too slow in this situation.)
    return if object_list.blank?
    fast_inserter_start_time = Time.current
    fast_inserter_variable_columns = object_list.first.keys.map(&:to_s)
    fast_inserter_values = object_list.map { |nvpp| nvpp.values }
    fast_inserter_params = {
      table: table_name,
      static_columns: {}, # values that are the same for each record
      options: {
        timestamps: true, # write created_at / updated_at
        group_size: 2_000,
      },
      variable_columns: fast_inserter_variable_columns, # column names of values that are different for each record
      values: fast_inserter_values, # values that are different for each record
    }
    model = table_name.classify.constantize # get Rails model class from table name
    last_id = model.order(id: :desc).first&.id || 0

    inserter = FastInserter::Base.new(fast_inserter_params)
    inserter.fast_insert
    # logger.info "#{table_name} fast_inserter complete in #{(Time.current - fast_inserter_start_time).round(2)} seconds"
    model_name = table_name.classify
    logger.info "#{fast_inserter_values.length} #{model_name}s fast-inserted"
    # Return an ActiveRecord relation with the objects just created
    model.where(['id > ?', last_id])
  end

  def self.grab_all
    # Call MTA ALL_VEHICLES_URL endpoint and make vehicle positions.
    # Runs every 30 seconds via grab_and_go.
    # Per the MTA, must not run more than once every 30 seconds.
    start_time = Time.current
    logger = Logger.new('log/grab.log')
    identifier = start_time.to_f.to_s.split(".")[1].first(4)
    logger.info "Starting grab_all # #{identifier} at #{start_time.in_time_zone("EST")}"

    # Check the previous API call
    previous_call = MtaApiCallRecord.most_recent
    last_id = 0
    if previous_call.present?
      logger.info "most recent timestamp: #{(Time.current - previous_call&.created_at).round(2)} seconds ago"
      last_id = previous_call.id
    end

    # Check if it's < 30 seconds old
    if previous_call.present? && previous_call.created_at > 30.seconds.ago # yes, > means younger than 30 seconds
      wait_time = 31 - (Time.current - previous_call.created_at).to_i
      wait_time += 4 if wait_time == 31
      # logger.info "grab_all called early; must wait at least 30 seconds between API calls"
      logger.info "Waiting an additional #{wait_time} seconds"
      sleep(wait_time)
      return self.grab_all
    end

    # Make the call
    MtaApiCallRecord.transaction do
      MtaApiCallRecord.lock.create() # no fields needed; just uses created_at timestamp
    end
    new_record = MtaApiCallRecord.most_recent
    if new_record.present? && new_record.id > last_id
      logger.info "Making MTA API call to ALL_VEHICLES_URL at #{Time.current.in_time_zone("EST")}"
      response = HTTParty.get(ApplicationController::ALL_VEHICLES_URL)
    else
      logger.info "Database lock encountered; skipping grab_all # #{identifier}"
      return
    end

    # Process the data and write to db
    object_list = VehiclePosition.extract_from_response(response)
    new_vehicle_positions = fast_insert_objects('vehicle_positions', object_list)

    logger.info "grab_all # #{identifier} complete in #{(Time.current - start_time).round(2)} seconds."

    new_vehicle_positions
  end

  def self.grab_and_go
    # Runs every 1 minute.  Runs grab_all either once or twice,
    # depending on if the first one takes > 30 seconds.
    start_time = Time.current
    logger = Logger.new('log/grab.log')
    identifier = start_time.to_f.to_s.split(".")[1].first(4)
    logger.info "Starting grab_and_go # #{identifier} at #{start_time.in_time_zone("EST")}"
    grab_all

    elapsed_time = Time.current - start_time
    if elapsed_time > 30.seconds
      logger.info "First grab_all took #{elapsed_time.round(2)} seconds; skipping second grab_all"
      return
    end

    logger.info "continuing grab_and_go # #{identifier} after #{elapsed_time.round(2)} seconds"
    grab_all
    logger.info "grab_and_go # #{identifier} complete in #{(Time.current - start_time).round(2)} seconds"
  end

  def self.is_departure?(old_vehicle_position, new_vehicle_position)
    return false if old_vehicle_position.blank? || new_vehicle_position.blank?
    # If all of the following rules apply, we consider it a departure:
    # timestamp for new_vehicle_position is after old_vehicle_position
    # vehicle_ref is the same
    # arrival_text for old_vehicle_position is 'at stop', 'approaching', or '< 1 stop away'
    # the two vehicle positions are less than 90 seconds apart
    # stop_ref changes
    # TODO: stop_ref changes to the NEXT stop on the route (not just any stop)

    return false unless new_vehicle_position.timestamp > old_vehicle_position.timestamp
    return false unless new_vehicle_position.vehicle_ref == old_vehicle_position.vehicle_ref
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
    self.scrape_from(VehiclePosition.newer_than(240))
  end

  def self.scrape_from(vehicle_positions)
    # Take a list of vehicle_positions, compare them, and create departures
    start_time = Time.current
    logger = Logger.new('log/grab.log')
    identifier = start_time.to_f.to_s.split(".")[1].first(4)
    logger.info "Starting departure scrape # #{identifier} at #{start_time.in_time_zone("EST")}"

    existing_count = HistoricalDeparture.all.count
    departures = []
    departure_ids = [] # keep track so we don't make duplicates

    vehicle_positions = vehicle_positions.group_by(&:vehicle_ref)
    # "MTABC_3742"=>[#<VehiclePosition ...>, #<VehiclePosition ...>, #<VehiclePosition ...>]
    # logger.info "Filtering #{vehicle_positions.length} vehicles"
    vehicle_positions.delete_if { |k, v| v.length < 2 }
    # logger.info "Filtered to #{vehicle_positions.length} vehicles with 2+ positions"
    ids_to_purge = []
    expired_count = 0
    addl_count = 0
    vehicle_positions.each do |veh_ref, vp_list|
      sorted_vps = vp_list.sort_by(&:timestamp) # guarantee that the oldest vehicle_position is first

      while sorted_vps.length > 1 do
        # Remove the oldest vehicle position
        old_vehicle_position = sorted_vps.shift

        # Compare it with every other position to see if we can make a departure
        sorted_vps.each do |new_vehicle_position|
          expired_count += 1 if expired_dep?(old_vehicle_position, new_vehicle_position)
          if is_departure?(old_vehicle_position, new_vehicle_position)
            addl_count += 1 if old_vehicle_position.arrival_text != "at stop"
            bus_stop = BusStop.find_or_create_by(stop_ref: new_vehicle_position.stop_ref)
            logger.error "bus_stop not found: #{new_vehicle_position.stop_ref}" if bus_stop.blank?
            next unless bus_stop.present?
            new_departure = {
              bus_stop_id: bus_stop.id,
              stop_ref: old_vehicle_position.stop_ref,
              line_ref: new_vehicle_position.line_ref,
              vehicle_ref: new_vehicle_position.vehicle_ref,
              departure_time: new_vehicle_position.timestamp - 30.seconds,
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

    HistoricalDeparture::fast_insert_objects('historical_departures', departures.compact.uniq)
    VehiclePosition.delete(ids_to_purge.take(65_535))

    logger.info "!------------- #{HistoricalDeparture.all.count - existing_count} historical departures created -------------!"
    logger.info "Avoided #{departures.compact.length - departures.compact.uniq.length} duplicate departures by removing non-unique values"
    # logger.info "#{expired_count} departures not created because vehicle positions were > 90 seconds apart" unless expired_count == 0
    logger.info "#{ids_to_purge.length} old vehicle positions purged"
    logger.info "Departure scrape # #{identifier} complete in #{(Time.current - start_time).round(2)} seconds"

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
    min_id = HistoricalDeparture.newer_than(age_in_secs).order(created_at: :desc).ids.first
    logger.info "Purging duplicate HistoricalDepartures with id > #{min_id}"
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
    result = ActiveRecord::Base.connection.execute(sql).first
    logger.info result
  end

  def self.update_count
    # Update the estimated historical_departures count for the stats API endpoint
    start_time = Time.current
    logger.info "Starting ANALYZE; ..."
    ActiveRecord::Base.connection.execute("ANALYZE;")
    logger.info "ANALYZE complete in #{(Time.current - start_time).round(2)} seconds"
  rescue(err)
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
    # 2 hours worth of historical_departures is typically 180,000+ records.
    # Here we're using the postgresql_cursor gem (each_row and each_instance methods)
    # to process all of them, hopefully without running out of memory or getting the process killed.
    HistoricalDeparture.lock.transaction do
      logger.info "Processing #{length} departures"

      current_batch = []
      current_batch_stop_ref = nil
      current_batch_line_ref = nil

      cursor = unsorted_historical_departures.order("stop_ref, line_ref, departure_time DESC").each_instance(block_size: block_size) do |current_departure|
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
          # print "total_count: #{total_count} | successful_count: #{successful_count} | current batch length: #{current_batch.length} \r"

          # clear out our workspace for the next batch
          current_batch = []
          current_batch_stop_ref = nil
          current_batch_line_ref = nil
          next
        end # if
      end # of cursor block
    end # of transaction

    # puts   # Uncomment this in tandem with the print on line 281
    logger.info "#{skip_non_nils ? 'Updated' : 'Updated & overwrote'} #{successful_count} headways."
    logger.info "Processed #{batch_count} stop_ref/line_ref combinations"
    logger.info "Skipped #{non_nils_skipped} headways that were already present" if skip_non_nils
    logger.info "Update failed for #{error_count} headways" if error_count > 0
    logger.info "Total headways processed: #{successful_count + batch_count + non_nils_skipped + error_count}"
    logger.info "calculate_headways done after #{(Time.current - start_time).round(2)} seconds"
    # logger.info "Including #{batch_elapsed_time.round(2)} seconds batch process time; which includes #{update_time.round(2)} seconds update time"
  end

  def self.process_batch(departure_arr, skip_non_nils = true)
    # Assume departure_arr is sorted by departure_time desc
    # Assume all departures in departure_arr have the same stop_ref and line_ref

    start_time = Time.current
    update_time = 0.0
    last_index = departure_arr.length - 1
    batch_count = 1
    error_count = 0
    successful_count = 0
    non_nils_skipped = 0

    departure_arr.each_with_index do |current_departure, idx|
      # Compare each departure time with the next departure
      # The headway is the number of seconds between them
      next if idx == last_index
      if skip_non_nils && current_departure.headway.present?
        non_nils_skipped += 1
        next # thank u
      end
      previous_departure = departure_arr[idx + 1]

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
      elapsed_time: Time.current - start_time,
      update_time: update_time,
    }
  end # of process_batch

end
