class VehiclePosition < ApplicationRecord

  include FastInsert
  include Wtf

  belongs_to :vehicle
  belongs_to :bus_line
  belongs_to :bus_stop

  validates_uniqueness_of :timestamp, scope: [:stop_ref, :vehicle_ref], message: "must have a unique vehicle_ref and stop_ref for a given timestamp"

  scope :at_stop, -> { where(arrival_text: "at stop") }
  scope :older_than, -> (num) { where(["timestamp < ?", num.seconds.ago]) }
  scope :newer_than, -> (num) { where(["timestamp > ?", num.seconds.ago]) }
  scope :for_vehicle, -> (vehicle_ref) { where(vehicle_ref: vehicle_ref) }

  def latest?
    self == self.vehicle.latest_position
  end

  def self.clean_up
    logger.info "VehiclePosition.clean_up"
    purge_older_than(480)
  end

  def self.purge_older_than(seconds)
    records_to_purge = self.older_than(seconds).ids.take(65_535)
    logger.info "Purging #{records_to_purge.length} old VehiclePositions"
    self.delete(records_to_purge)
    logger.info "#{VehiclePosition.all.count} VehiclePositions remaining in database"
    self.count_duplicates
  end

  def self.prevent_duplicates(objects_to_be_added, existing_vehicle_positions)
    # Pass in a list of objects from which VehiclePositions will be created, and compare them to a list of existing VehiclePosition records.
    # Return only the objects which would not be duplicates.
    # Additionally, if duplicates are found within the existing VehiclePositions, delete them.

    start_time = Time.current
    logger.info "VehiclePosition prevent_duplicates starting..."

    # Coming in, we have an array of hashes and an ActiveRecord::Relation.
    # Combine both lists into one array of hashes, with the existing departures first.
    # Use transform_keys on objects_to_be_added to ensure that all keys are strings and not symbols.
    object_list = existing_vehicle_positions.map(&:attributes) + objects_to_be_added.map { |d| d.transform_keys { |k| k.to_s } }

    # Create a tracking hash to remember which departures we've already seen
    already_seen = {}

    # Create a list of existing IDs to delete
    ids_to_purge = []

    dup_count = 0

    # Move through the object list and check for duplicates
    object_list.each do |dep|
      tracking_key = "#{dep["timestamp"].to_i} #{dep["vehicle_ref"]} #{dep["stop_ref"]}"
      if already_seen[tracking_key]
        dup_count += 1
        # print "dups: #{dup_count} | already seen: #{tracking_key}                \r"
        unless dep["id"].nil?
          # Always keep the VehiclePosition with the smaller ID, and delete the one with the larger ID.
          # If this method happens to be running in 2 processes with the same 2 duplicates, this way we always pick the same one to delete.
          ids_to_purge << [dep["id"], already_seen[tracking_key]["id"]].max
        end
      else
        # print "dups: #{dup_count} | new: #{tracking_key}            \r"
        already_seen[tracking_key] = dep
      end
    end
    logger.info "#{dup_count} duplicates found"
    puts

    # Delete pre-existing duplicates
    unless ids_to_purge.length == 0
      logger.info "prevent_duplicates: Deleting #{ids_to_purge.length} duplicate VehiclePositions"
      self.delete(ids_to_purge)
    end

    # Assemble result
    # Return the unique list of values, but only keep values having no ID.
    # This ensures we don't try to re-create existing records.
    result = already_seen.values.select { |dep| dep["id"].nil? }

    # Log results
    prevented_count = objects_to_be_added.length - result.length
    unless prevented_count == 0
      logger.info "prevent_duplicates: Prevented #{prevented_count} duplicate VehiclePositions"
      logger.info "prevent_duplicates: Filtered to #{result.length} unique objects"
    end
    logger.info "prevent_duplicates complete after #{(Time.current - start_time).round(2)} seconds"

    result
  end

  def self.count_duplicates
    dup_count = self.duplicates.length
    logger.info "#{dup_count} duplicate VehiclePositions counted"
  end

  def self.purge_duplicates_newer_than(age_in_secs)
    min_id = VehiclePosition.newer_than(age_in_secs).order(created_at: :asc).ids.first || 0
    logger.info "Purging duplicate VehiclePositions with id > #{min_id}"
    sql = <<~HEREDOC
      DELETE FROM vehicle_positions T1
      USING vehicle_positions T2
      WHERE T1.id > T2.id
      AND T1.id > #{min_id}
      AND T1.timestamp = T2.timestamp
      AND T1.stop_ref = T2.stop_ref
      AND T1.vehicle_ref = T2.vehicle_ref
      ;
    HEREDOC
    result = ActiveRecord::Base.connection.execute(sql).first
    logger.info result
  end

  def self.is_duplicate?(vp_a, vp_b)
    # Unlike HistoricalDeparture, we cannot use the trip identifier to check for VehiclePosition duplicates.
    # If two VehiclePositions have the same trip identifier etc. but different timestamps, they are both valid.
    if vp_a.timestamp == vp_b.timestamp &&
      vp_a.vehicle_ref == vp_b.vehicle_ref &&
      vp_a.stop_ref == vp_b.stop_ref
      return true
    end
    false
  end

  def skinny_attributes
    skinny = self.attributes
    skinny.delete "id"
    skinny.delete "vehicle_id"
    skinny.delete "bus_line_id"
    skinny.delete "bus_stop_id"
    skinny.delete "created_at"
    skinny.delete "updated_at"
    skinny.delete "feet_from_stop"
    skinny
  end

  def self.duplicates
    VehiclePosition.newer_than(240).select(:vehicle_ref, :line_ref, :arrival_text, :stop_ref, :timestamp)
                                   .group(:vehicle_ref, :line_ref, :arrival_text, :stop_ref, :timestamp)
                                   .having("count(*) > 1")
  end

  def self.grab_all
    # Call MTA ALL_VEHICLES_URL endpoint and make vehicle positions.
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
      # wait_time = 31 - (Time.current - previous_call.created_at).to_i
      # wait_time += 4 if wait_time == 31
      logger.info "skipping grab_all; must wait at least 30 seconds between API calls"
      return
      # logger.info "Waiting an additional #{wait_time} seconds"
      # sleep(wait_time)
      # return self.grab_all
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

    # Prevent duplicates
    uniq_object_list = VehiclePosition.prevent_duplicates(object_list, VehiclePosition.newer_than(1_200).reload)

    # Use Fast Inserter gem
    logger.info "Using fast inserter gem"
    fast_insert_objects('vehicle_positions', uniq_object_list)

    # Use regular ActiveRecord - checks for dups before saving
    # logger.info "Using Active Record to insert vehicle positions"
    # error_count = 0
    # uniq_object_list.each do |vp_attrs|
    #   new_vp = VehiclePosition.create(vp_attrs)
    #   if new_vp.errors.any?
    #     error_count += 1
    #   end
    #   new_vp
    # end
    #
    # logger.info "#{error_count} duplicate vehicle positions avoided"
    logger.info "grab_all # #{identifier} complete in #{(Time.current - start_time).round(2)} seconds."
  end

  def self.wait_and_grab(wait_time = 32)
    # Wait 30 seconds, then run grab_all.  This is so grab_all can run every 30 seconds, even though
    # the minimum interval supported by cron is 1 minute.
    logger = Logger.new('log/grab.log')
    logger.info "Waiting #{wait_time} seconds"
    sleep(wait_time)
    logger.info "Starting grab_all after waiting #{wait_time} seconds"
    grab_all
  end

  def self.grab_all_for_route(route_id)
    # Get all vehicle positions for a given bus line
    url_addon = ERB::Util.url_encode(route_id)
    url = ApplicationController::LIST_OF_VEHICLES_URL + "&LineRef=" + url_addon
    response = HTTParty.get(url)

    # Format the data
    vehicle_positions_a = VehiclePosition.extract_from_response(response)
    self.fast_insert_objects('vehicle_positions', vehicle_positions_a)
  end

  def self.extract_single(data)
    # Pass in an object containing a single MonitoredVehicleJourney object
    return nil unless data['MonitoredVehicleJourney'].present?
    vehicle_ref = data['MonitoredVehicleJourney']['VehicleRef']
    line_ref = data['MonitoredVehicleJourney']['LineRef']
    direction_ref = nil
    if data['MonitoredVehicleJourney']['DirectionRef'].present?
      direction_ref = data['MonitoredVehicleJourney']['DirectionRef'].to_i
    end
    return nil unless vehicle_ref.present? && line_ref.present?
    return nil unless data['MonitoredVehicleJourney']['MonitoredCall'].present?
    arrival_text = data['MonitoredVehicleJourney']['MonitoredCall']['ArrivalProximityText']
    feet_from_stop = data['MonitoredVehicleJourney']['MonitoredCall']['DistanceFromStop']
    stop_ref = data['MonitoredVehicleJourney']['MonitoredCall']['StopPointRef']
    return nil unless stop_ref.present?
    timestamp = data['RecordedAtTime']

    block_ref = data['MonitoredVehicleJourney']['BlockRef']
    dated_vehicle_journey_ref = nil
    if data['MonitoredVehicleJourney']['FramedVehicleJourneyRef'].present?
      dated_vehicle_journey_ref = data['MonitoredVehicleJourney']['FramedVehicleJourneyRef']['DatedVehicleJourneyRef']
    end

    vehicle = Vehicle.find_or_create_by(vehicle_ref: vehicle_ref)
    bus_line = BusLine.find_by(line_ref: line_ref)
    bus_stop = BusStop.find_or_create_by(stop_ref: stop_ref)

    return nil unless vehicle.present? && bus_line.present? && bus_stop.present?
    {
        vehicle_id: vehicle.id,
        bus_line_id: bus_line.id,
        bus_stop_id: bus_stop.id,
        vehicle_ref: vehicle_ref,
        line_ref: line_ref,
        direction_ref: direction_ref,
        arrival_text: arrival_text,
        feet_from_stop: feet_from_stop,
        stop_ref: stop_ref,
        timestamp: Time.rfc3339(timestamp),
        block_ref: block_ref,
        dated_vehicle_journey_ref: dated_vehicle_journey_ref,
    }
  end

  def self.extract_from_response(response)
    start_time = Time.current
    existing_vehicle_count = Vehicle.all.count
    existing_stop_count = BusStop.all.count
    if BusLine.all.count == 0
      logger.error "No BusLines in database"
      return
    end
    return [] unless response['Siri']['ServiceDelivery']['VehicleMonitoringDelivery'].present?
    return [] unless response['Siri']['ServiceDelivery']['VehicleMonitoringDelivery'][0].present?
    vehicle_activity = response['Siri']['ServiceDelivery']['VehicleMonitoringDelivery'][0]['VehicleActivity']
    logger.info "VehiclePosition.extract_from_response starting for #{vehicle_activity.length} vehicle positions"
    # duplicates_avoided = 0
    begin
    new_vehicle_position_params = vehicle_activity.map do |data|
      if (Time.current - start_time) > 300
        logger.warn "VehiclePosition.extract_from_response took > 300 seconds; aborting"
        break
      end
      VehiclePosition.extract_single(data)
    end.compact
    rescue NoMethodError
      # if the map is aborted by the break, it will return nil so .compact will throw a NoMethodError.
      new_vehicle_position_params = []
    end

    new_vehicle_count = Vehicle.all.count - existing_vehicle_count
    new_stop_count = BusStop.all.count - existing_stop_count
    logger.info "#{new_vehicle_count} Vehicles created" if new_vehicle_count > 0
    logger.info "#{new_stop_count} BusStops created" if new_stop_count > 0
    logger.info "VehiclePosition.extract_from_response complete in #{(Time.current - start_time).round(2)} seconds"
    new_vehicle_position_params
  end

  # Instance methods

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
