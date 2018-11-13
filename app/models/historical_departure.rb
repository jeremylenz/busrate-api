class HistoricalDeparture < ApplicationRecord

  belongs_to :bus_stop

  scope :newer_than, -> (num) { where(["departure_time > ?", num.seconds.ago]) }

  def self.for_route_and_stop(line_ref, stop_ref)
    self.where(line_ref: line_ref, stop_ref: stop_ref).order(departure_time: :desc)
  end

  def self.grab_vehicle_positions_for_route(route_id)
    # Get all vehicle positions for a given bus line
    url_addon = ERB::Util.url_encode(route_id)
    url = ApplicationController::LIST_OF_VEHICLES_URL + "&LineRef=" + url_addon
    response = HTTParty.get(url)

    # Format the data
    vehicle_positions_a = extract_vehicle_positions(response)
    fast_insert_objects('vehicle_positions', vehicle_positions_a)
  end

  def self.extract_vehicle_positions(response)
    start_time = Time.current
    existing_vehicle_count = Vehicle.all.count
    existing_stop_count = BusStop.all.count
    if BusLine.all.count == 0
      logger.error "No BusLines in database"
      return
    end
    timestamp = response['Siri']['ServiceDelivery']['ResponseTimestamp']
    return [] unless response['Siri']['ServiceDelivery']['VehicleMonitoringDelivery'][0].present?
    vehicle_activity = response['Siri']['ServiceDelivery']['VehicleMonitoringDelivery'][0]['VehicleActivity']
    # duplicates_avoided = 0
    new_vehicle_position_params = vehicle_activity.map do |data|
      next unless data['MonitoredVehicleJourney'].present?
      vehicle_ref = data['MonitoredVehicleJourney']['VehicleRef']
      line_ref = data['MonitoredVehicleJourney']['LineRef']
      next unless vehicle_ref.present? && line_ref.present?
      next unless data['MonitoredVehicleJourney']['MonitoredCall'].present?
      arrival_text = data['MonitoredVehicleJourney']['MonitoredCall']['ArrivalProximityText']
      feet_from_stop = data['MonitoredVehicleJourney']['MonitoredCall']['DistanceFromStop']
      stop_ref = data['MonitoredVehicleJourney']['MonitoredCall']['StopPointRef']

      # existing_vehicle_position = VehiclePosition.find_by(
      #   vehicle_ref: vehicle_ref,
      #   stop_ref: stop_ref,
      #   timestamp: Time.zone.rfc3339(timestamp),
      # )
      # duplicates_avoided += 1 if existing_vehicle_position.present?
      # next unless existing_vehicle_position.blank? # Avoid creating duplicate VehiclePositions

      vehicle = Vehicle.find_or_create_by(vehicle_ref: vehicle_ref)
      bus_line = BusLine.find_by(line_ref: line_ref)
      bus_stop = BusStop.find_or_create_by(stop_ref: stop_ref)

      next unless vehicle.present? && bus_line.present? && bus_stop.present?
      {
          vehicle_id: vehicle.id,
          bus_line_id: bus_line.id,
          bus_stop_id: bus_stop.id,
          vehicle_ref: vehicle_ref,
          line_ref: line_ref,
          arrival_text: arrival_text,
          feet_from_stop: feet_from_stop,
          stop_ref: stop_ref,
          timestamp: Time.rfc3339(timestamp),
      }
    end.compact
    return [] if new_vehicle_position_params.empty?

    new_vehicle_count = Vehicle.all.count - existing_vehicle_count
    new_stop_count = BusStop.all.count - existing_stop_count
    logger.info "#{new_vehicle_count} Vehicles created" if new_vehicle_count > 0
    logger.info "#{new_stop_count} BusStops created" if new_stop_count > 0
    # logger.info "Avoided creating #{duplicates_avoided} duplicate VehiclePositions"
    logger.info "extract_vehicle_positions complete in #{Time.current - start_time} seconds"
    new_vehicle_position_params
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
    logger.info "#{table_name} fast_inserter complete in #{Time.current - fast_inserter_start_time} seconds"
    model_name = table_name.classify
    logger.info "#{fast_inserter_values.length} #{model_name}s fast-inserted"
    # Return an ActiveRecord relation with the objects just created
    model.where(['id > ?', last_id])
  end

  def self.grab_all
    start_time = Time.current
    identifier = start_time.to_i.to_s.last(4)
    logger.info "Starting grab_all # #{identifier} at #{start_time.in_time_zone("EST")}"

    previous_call = MtaApiCallRecord.most_recent
    if previous_call.present?
      logger.info "most recent timestamp: #{Time.current - previous_call&.created_at} seconds ago"
    end

    if previous_call.present? && previous_call.created_at > 30.seconds.ago
      wait_time = 30 - (Time.current - previous_call.created_at).to_i
      logger.info "grab_all called early; must wait at least 30 seconds between API calls"
      logger.info "Waiting an additional #{wait_time} seconds"
      sleep(wait_time)
      return self.grab_all
    end
    logger.info "Making MTA API call to ALL_VEHICLES_URL at #{Time.current.in_time_zone("EST")}"
    MtaApiCallRecord.create() # no fields needed; just uses created_at timestamp
    response = HTTParty.get(ApplicationController::ALL_VEHICLES_URL)
    object_list = extract_vehicle_positions(response)
    new_vehicle_positions = fast_insert_objects('vehicle_positions', object_list)

    logger.info "grab_all # #{identifier} complete in #{Time.current - start_time} seconds."

    new_vehicle_positions
  end

  def self.grab_and_go
    start_time = Time.current
    logger.info "Starting grab_and_go at #{start_time.in_time_zone("EST")}"
    pos1 = grab_all
    logger.info "continuing after #{Time.current - start_time} seconds"
    pos2 = grab_all
    VehiclePosition.scrape_all_departures
    logger.info "grab_and_go complete in #{Time.current - start_time} seconds"
  end

end
