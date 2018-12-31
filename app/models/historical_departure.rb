class HistoricalDeparture < ApplicationRecord

  belongs_to :bus_stop
  belongs_to :previous_departure, class_name: "HistoricalDeparture"
  validates :headway, numericality: {greater_than: 0, allow_nil: true}

  scope :newer_than, -> (num) { where(["departure_time > ?", num.seconds.ago]) }

  def self.for_route_and_stop(line_ref, stop_ref)
    self.where(line_ref: line_ref, stop_ref: stop_ref).order(departure_time: :desc)
  end

  def self.fast_insert_objects(table_name, object_list)
    return if object_list.blank?
    fast_inserter_start_time = Time.current
    fast_inserter_variable_columns = object_list.first.keys.map(&:to_s)
    fast_inserter_values = object_list.map { |nvpp| nvpp.values }
    fast_inserter_params = {
      table: table_name,
      static_columns: {},
      options: {
        timestamps: true,
        group_size: 2_000,
      },
      variable_columns: fast_inserter_variable_columns,
      values: fast_inserter_values,
    }
    model = table_name.classify.constantize # get Rails model class from table name
    last_id = model.order(id: :desc).first&.id || 0

    inserter = FastInserter::Base.new(fast_inserter_params)
    inserter.fast_insert
    # logger.info "#{table_name} fast_inserter complete in #{Time.current - fast_inserter_start_time} seconds"
    model_name = table_name.classify
    logger.info "#{fast_inserter_values.length} #{model_name}s fast-inserted"
    # Return an ActiveRecord relation with the objects just created
    model.where(['id > ?', last_id])
  end

  def self.grab_all
    start_time = Time.current
    logger = Logger.new('log/grab.log')
    identifier = start_time.to_f.to_s.split(".")[1].first(4)
    logger.info "Starting grab_all # #{identifier} at #{start_time.in_time_zone("EST")}"

    previous_call = MtaApiCallRecord.most_recent
    last_id = 0
    if previous_call.present?
      logger.info "most recent timestamp: #{Time.current - previous_call&.created_at} seconds ago"
      last_id = previous_call.id
    end

    if previous_call.present? && previous_call.created_at > 30.seconds.ago
      wait_time = 31 - (Time.current - previous_call.created_at).to_i
      wait_time += 4 if wait_time == 31
      # logger.info "grab_all called early; must wait at least 30 seconds between API calls"
      logger.info "Waiting an additional #{wait_time} seconds"
      sleep(wait_time)
      return self.grab_all
    end

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

    object_list = VehiclePosition.extract_from_response(response)
    new_vehicle_positions = fast_insert_objects('vehicle_positions', object_list)

    logger.info "grab_all # #{identifier} complete in #{Time.current - start_time} seconds."

    new_vehicle_positions
  end

  def self.grab_and_go
    start_time = Time.current
    logger = Logger.new('log/grab.log')
    identifier = start_time.to_f.to_s.split(".")[1].first(4)
    logger.info "Starting grab_and_go # #{identifier} at #{start_time.in_time_zone("EST")}"
    grab_all

    elapsed_time = Time.current - start_time
    if elapsed_time > 30.seconds
      logger.info "First grab_all took #{elapsed_time} seconds; skipping second grab_all"
      return
    end

    logger.info "continuing grab_and_go # #{identifier} after #{elapsed_time} seconds"
    grab_all
    logger.info "grab_and_go # #{identifier} complete in #{Time.current - start_time} seconds"
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
    logger.info "Departure scrape # #{identifier} complete in #{Time.current - start_time} seconds"

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

  def self.doit(age_in_secs, skip_non_nils = true)
    hds = HistoricalDeparture.newer_than(age_in_secs)
    HistoricalDeparture.calculate_headways(hds, skip_non_nils)
  end

  def self.calculate_headways(unsorted_historical_departures, skip_non_nils = true)
    return if unsorted_historical_departures.blank? || unsorted_historical_departures.length < 2
    deps = unsorted_historical_departures.order("stop_ref, line_ref, departure_time DESC").limit(20_000) # make sure it's sorted
    process_headways(deps, skip_non_nils)
  end

  def self.process_headways(sorted_deps, skip_non_nils = true)
    return if sorted_deps.blank? || sorted_deps.length < 2
    start_time = Time.current
    last_index = sorted_deps.count - 1
    logger.info "Calculating #{last_index} headways"
    successful_count = 0
    failure_count = 0
    error_count = 0
    non_nils_skipped = 0
    sorted_deps.each_with_index do |current_departure, idx|
      next if idx == last_index
      if skip_non_nils && current_departure.headway.present?
        # skip departures that already have a value for headway
        non_nils_skipped += 1
        next # thank u
      end
      previous_departure = sorted_deps[idx + 1]
      unless current_departure.stop_ref == previous_departure.stop_ref && current_departure.line_ref == previous_departure.line_ref
        failure_count += 1
        print "failure_count: #{failure_count}        \r"
        next
      end
      prev_id = previous_departure.id
      headway = (current_departure.departure_time - previous_departure.departure_time).round.to_i
      headway = nil if headway == 0
      current_departure.update(
        headway: headway,
        previous_departure_id: prev_id,
      )

      if current_departure.errors.any?
        logger.info "Problem updating departure #{current_departure.id}: #{current_departure.errors.full_messages.join("; ")}"
        error_count += 1
      else
        successful_count += 1
        print "successful_count: #{successful_count}\r"
      end
    end
    logger.info "Updated #{successful_count} headways."
    logger.info "Skipped #{failure_count} headways due to stop_ref/line_ref mismatch"
    logger.info "Skipped #{non_nils_skipped} headways that were already present"
    logger.info "Update failed for #{error_count} headways"
    logger.info "Total #{successful_count + failure_count + error_count}"
    logger.info "process_headways done after #{Time.current - start_time} seconds"

  end

end
