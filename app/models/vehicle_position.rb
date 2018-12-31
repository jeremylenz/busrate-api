class VehiclePosition < ApplicationRecord

  belongs_to :vehicle
  belongs_to :bus_line
  belongs_to :bus_stop

  scope :at_stop, -> { where(arrival_text: "at stop") }
  scope :older_than, -> (num) { where(["timestamp < ?", num.seconds.ago]) }
  scope :newer_than, -> (num) { where(["timestamp > ?", num.seconds.ago]) }
  scope :active, -> { at_stop.older_than(30).newer_than(120) }

  def latest?
    self == self.vehicle.latest_position
  end

  def self.clean_up
    logger.info "VehiclePosition.clean_up"
    purge_older_than(480)
  end

  def self.purge_older_than(seconds)
    records_to_purge = self.older_than(seconds).ids.take(65_535)
    logger.info "Purging #{records_to_purge.length} VehiclePositions"
    self.delete(records_to_purge)
    logger.info "#{VehiclePosition.all.count} VehiclePositions remaining in database"
    self.count_duplicates
  end

  def self.count_duplicates
    dup_count = self.duplicates.length
    logger.info "#{dup_count} duplicate VehiclePositions counted"
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

  def self.grab_all_for_route(route_id)
    # Get all vehicle positions for a given bus line
    url_addon = ERB::Util.url_encode(route_id)
    url = ApplicationController::LIST_OF_VEHICLES_URL + "&LineRef=" + url_addon
    response = HTTParty.get(url)

    # Format the data
    vehicle_positions_a = VehiclePosition.extract_from_response(response)
    HistoricalDeparture.fast_insert_objects('vehicle_positions', vehicle_positions_a)
  end

  def self.extract_single(data)
    # Pass in an object containing a single MonitoredVehicleJourney object
    return nil unless data['MonitoredVehicleJourney'].present?
    vehicle_ref = data['MonitoredVehicleJourney']['VehicleRef']
    line_ref = data['MonitoredVehicleJourney']['LineRef']
    return nil unless vehicle_ref.present? && line_ref.present?
    return nil unless data['MonitoredVehicleJourney']['MonitoredCall'].present?
    arrival_text = data['MonitoredVehicleJourney']['MonitoredCall']['ArrivalProximityText']
    feet_from_stop = data['MonitoredVehicleJourney']['MonitoredCall']['DistanceFromStop']
    stop_ref = data['MonitoredVehicleJourney']['MonitoredCall']['StopPointRef']
    timestamp = data['RecordedAtTime']

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
        arrival_text: arrival_text,
        feet_from_stop: feet_from_stop,
        stop_ref: stop_ref,
        timestamp: Time.rfc3339(timestamp),
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
    # duplicates_avoided = 0
    new_vehicle_position_params = vehicle_activity.map do |data|
      VehiclePosition.extract_single(data)
    end.compact

    new_vehicle_count = Vehicle.all.count - existing_vehicle_count
    new_stop_count = BusStop.all.count - existing_stop_count
    logger.info "#{new_vehicle_count} Vehicles created" if new_vehicle_count > 0
    logger.info "#{new_stop_count} BusStops created" if new_stop_count > 0
    logger.info "VehiclePosition.extract_from_response complete in #{Time.current - start_time} seconds"
    new_vehicle_position_params
  end


end
