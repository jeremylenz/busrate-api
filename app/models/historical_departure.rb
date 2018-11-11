class HistoricalDeparture < ApplicationRecord

  def self.grab_vehicle_positions(route_id)
    # Get all vehicle positions for a given bus line
    url_addon = ERB::Util.url_encode(route_id)
    url = ApplicationController::LIST_OF_VEHICLES_URL + "&LineRef=" + url_addon
    response = HTTParty.get(url)

    # Format the data
    extract_vehicle_positions(response)
  end

  def self.extract_vehicle_positions(response)
    start_time = Time.current
    existing_count = VehiclePosition.all.count
    timestamp = response['Siri']['ServiceDelivery']['ResponseTimestamp']
    return [] unless response['Siri']['ServiceDelivery']['VehicleMonitoringDelivery'][0].present?
    vehicle_activity = response['Siri']['ServiceDelivery']['VehicleMonitoringDelivery'][0]['VehicleActivity']
    new_vehicle_position_params = vehicle_activity.map do |data|
      next unless data['MonitoredVehicleJourney'].present?
      vehicle_ref = data['MonitoredVehicleJourney']['VehicleRef']
      line_ref = data['MonitoredVehicleJourney']['LineRef']
      next unless vehicle_ref.present? && line_ref.present?
      next unless data['MonitoredVehicleJourney']['MonitoredCall'].present?
      arrival_text = data['MonitoredVehicleJourney']['MonitoredCall']['ArrivalProximityText']
      feet_from_stop = data['MonitoredVehicleJourney']['MonitoredCall']['DistanceFromStop']
      stop_ref = data['MonitoredVehicleJourney']['MonitoredCall']['StopPointRef']
      vehicle = Vehicle.find_or_create_by(vehicle_ref: vehicle_ref)
      bus_line = BusLine.find_by(line_ref: line_ref)
      next unless vehicle.present? && bus_line.present?
      {
          vehicle_id: vehicle.id,
          bus_line_id: bus_line.id,
          vehicle_ref: vehicle_ref,
          line_ref: line_ref,
          arrival_text: arrival_text,
          feet_from_stop: feet_from_stop,
          stop_ref: stop_ref,
          timestamp: Time.rfc3339(timestamp),
      }
    end.compact
    return [] if new_vehicle_position_params.empty?
    last_id = VehiclePosition.order(id: :desc).first&.id || 0

    fast_insert_objects('vehicle_positions', new_vehicle_position_params)

    logger.info "#{VehiclePosition.all.count - existing_count} VehiclePositions created"
    logger.info "extract_vehicle_positions complete in #{Time.current - start_time} seconds"
    VehiclePosition.where(['id > ?', last_id])
  end

  def self.fast_insert_objects(table_name, object_list)
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
    inserter = FastInserter::Base.new(fast_inserter_params)
    inserter.fast_insert
    logger.info "#{table_name} fast_inserter complete in #{Time.current - fast_inserter_start_time} seconds"
  end

  def self.scrape_departures(old_vehicle_positions, new_vehicle_positions)
    start_time = Time.current
    departures = []
    old_vehicle_positions.each do |old_vehicle_position|
      next unless old_vehicle_position.present?
      # find the corresponding new_vehicle_position
      next_position = new_vehicle_positions.find do |new_vehicle_position|
        new_vehicle_position.vehicle_ref == old_vehicle_position.vehicle_ref
      end
      next unless next_position.present?
      if is_departure?(old_vehicle_position, next_position)
        new_departure = {
          stop_ref: next_position.stop_ref,
          line_ref: next_position.line_ref,
          vehicle_ref: next_position.vehicle_ref,
          departure_time: next_position.timestamp,
        }
        departures << new_departure
      end
    end
    logger.info "scrape_departures ready for fast inserter after #{Time.current - start_time} seconds"

    fast_inserter_start_time = Time.current
    fast_inserter_variable_columns = ['stop_ref', 'line_ref', 'vehicle_ref', 'departure_time']
    fast_inserter_values = departures.map do |dep|
      [dep[:stop_ref], dep[:line_ref], dep[:vehicle_ref], dep[:departure_time]]
    end
    fast_inserter_params = {
      table: 'historical_departures',
      static_columns: {},
      options: {
        timestamps: true,
        group_size: 2_000,
      },
      variable_columns: fast_inserter_variable_columns,
      values: fast_inserter_values,
    }
    inserter = FastInserter::Base.new(fast_inserter_params)
    inserter.fast_insert

    logger.info "scrape_departures fast inserter complete in #{Time.current - start_time} seconds"
    logger.info "scrape_departures complete in #{Time.current - start_time} seconds"
    departures

  end

  def self.is_departure?(old_vehicle_position, new_vehicle_position)
    return false if old_vehicle_position.blank? || new_vehicle_position.blank?
    # If all of the following rules apply, we consider it a departure:
    # vehicle_ref is the same
    # arrival_text for old_vehicle_position is 'at stop'
    # the two vehicle positions are less than 2 minutes apart
    # stop_ref changes
    # TODO: stop_ref changes to the NEXT stop on the route (not just any stop)

    departure = true
    departure = false if new_vehicle_position.vehicle_ref != old_vehicle_position.vehicle_ref
    departure = false if old_vehicle_position.arrival_text != "at stop"
    departure = false if new_vehicle_position.stop_ref == old_vehicle_position.stop_ref
    departure = false if new_vehicle_position.timestamp - old_vehicle_position.timestamp > 2.minutes

    if new_vehicle_position.timestamp - old_vehicle_position.timestamp > 2.minutes
      logger.info "Departure not created; intervening time is #{new_vehicle_position.timestamp - old_vehicle_position.timestamp} seconds"
    end
    departure
  end

  def self.grab_all_by_line
    start_time = Time.current
    mta = HTTParty.get(ApplicationController::LIST_OF_MTA_BUS_ROUTES_URL)
    nyct = HTTParty.get(ApplicationController::LIST_OF_NYCT_BUS_ROUTES_URL)
    response = mta
    data_list = mta['data']['list'] + nyct['data']['list']
    bus_line_list = data_list.map { |el| el["id"] }
    count = 0

    vehicle_positions_a = {}
    puts "round 1"
    bus_line_list.each do |route_id|
      $stdout.flush
      print "#{route_id}\r"
      $stdout.flush
      vehicle_positions_a[route_id] = grab_vehicle_positions(route_id)
    end
    puts "\nround 2"
    vehicle_positions_b = {}
    bus_line_list.each do |route_id|
      $stdout.flush
      print "#{route_id}\r"
      $stdout.flush
      vehicle_positions_b[route_id] = grab_vehicle_positions(route_id)
    end

    puts "scraping..."
    vehicle_positions_a.keys.each do |route_id|
      new_departures = scrape_departures(vehicle_positions_a[route_id], vehicle_positions_b[route_id])
      next if new_departures.blank?
      count += new_departures.length
    end

    logger.info "grab_all_by_line complete in #{Time.current - start_time} seconds"
    puts "#{count} HistoricalDepartures created."

  end

  def self.grab_all
    start_time = Time.current
    existing_count = HistoricalDeparture.all.count
    response = HTTParty.get(ApplicationController::ALL_VEHICLES_URL)
    vehicle_positions_a = extract_vehicle_positions(response)

    logger.info "grab_all complete in #{Time.current - start_time} seconds."
    vehicle_positions_a
  end

  def self.grab_all_smart
    start_time = Time.current
    existing_count = HistoricalDeparture.all.count

    puts "round 1"
    response = HTTParty.get(ApplicationController::ALL_VEHICLES_URL)
    # byebug
    vehicle_positions_a = extract_vehicle_positions(response)
    puts "waiting"
    sleep(10)

    puts "round 2"
    vehicles_at_stop = vehicle_positions_a.select { |vp| vp.arrival_text == "at stop" }
    lines_to_check = vehicles_at_stop.map { |veh| veh.line_ref }.compact.uniq
    puts "Checking #{vehicles_at_stop.length} of #{vehicle_positions_a.length} vehicles"
    puts "Checking #{lines_to_check.length} lines"
    vehicle_positions_b = []
    lines_to_check.each do |route_id|
      $stdout.flush
      print "#{route_id}\r"
      $stdout.flush
      vehicle_positions_b << grab_vehicle_positions(route_id)
    end
    vehicle_positions_b.flatten!
    vehicle_positions_b.compact!
    puts "extracting"
    scrape_departures(vehicle_positions_a, vehicle_positions_b)

    new_count = HistoricalDeparture.all.count - existing_count
    puts "#{new_count} historical departures created."
    logger.info "grab_all_smart complete in #{Time.current - start_time} seconds."
  end

  def self.smart_survey
    stale_vehicle_positions = VehiclePosition.at_stop.older_than(30).newer_than(120)
    survey(stale_vehicle_positions)
  end

  def self.survey(stale_vehicle_positions)
    start_time = Time.current
    return if stale_vehicle_positions.blank?
    existing_count = HistoricalDeparture.all.count
    existing_vp_count = VehiclePosition.all.count

    vehicles_to_check = stale_vehicle_positions.map { |vp| vp.vehicle }
    vehicle_positions_to_check = vehicles_to_check.map { |vehicle| vehicle.latest_position }.compact
    new_vehicle_positions = []
    vehicle_positions_to_check.each do |vp|
      next if vp.blank?
      url_addon = ERB::Util.url_encode(vp.vehicle_ref)
      url = ApplicationController::LIST_OF_VEHICLES_URL + "&VehicleRef=" + url_addon
      response = HTTParty.get(url)
      # Format the data
      new_vehicle_positions << extract_vehicle_positions(response)

    end
    new_vehicle_positions.flatten!
    new_vehicle_positions.compact!
    scrape_departures(vehicle_positions_to_check, new_vehicle_positions)

    new_count = HistoricalDeparture.all.count - existing_count
    logger.info "#{new_count} historical departures created."
    logger.info "#{VehiclePosition.all.count - existing_vp_count} VehiclePositions created."
    logger.info "survey complete in #{Time.current - start_time} seconds."
  end

end
