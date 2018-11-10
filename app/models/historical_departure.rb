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
    timestamp = response['Siri']['ServiceDelivery']['ResponseTimestamp']
    return {} unless response['Siri']['ServiceDelivery']['VehicleMonitoringDelivery'][0].present?
    vehicle_activity = response['Siri']['ServiceDelivery']['VehicleMonitoringDelivery'][0]['VehicleActivity']
    vehicle_activity.map do |data|
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

      VehiclePosition.create(

          vehicle: vehicle,
          bus_line: bus_line,
          vehicle_ref: vehicle_ref,
          line_ref: line_ref,
          arrival_text: arrival_text,
          feet_from_stop: feet_from_stop,
          stop_ref: stop_ref,
          timestamp: timestamp,
        )
    end.compact
  end

  def self.scrape_departures(old_vehicle_positions, new_vehicle_positions)
    departures = []
    old_vehicle_positions.each do |old_vehicle_position|
      next unless old_vehicle_position.present?
      # find the corresponding new_vehicle_position
      next_position = new_vehicle_positions.find do |new_vehicle_position|
        new_vehicle_position.vehicle_ref == old_vehicle_position.vehicle_ref
      end
      next unless next_position.present?
      if is_departure?(old_vehicle_position, next_position)
        comparison = {
          old: old_vehicle_position,
          new: next_position,
          departed_at: next_position[:timestamp]
        }
        departures << comparison
        HistoricalDeparture.create(
          stop_ref: comparison[:new].stop_ref,
          line_ref: comparison[:new].line_ref,
          vehicle_ref: comparison[:new].vehicle_ref,
          departure_time: comparison[:departed_at]
        )
      end
    end
    departures

  end

  def self.is_departure?(old_vehicle_position, new_vehicle_position)
    return false if old_vehicle_position.blank? || new_vehicle_position.blank?
    # If all of the following rules apply, we consider it a departure:
    # vehicle_ref is the same
    # arrival_text goes from 'at stop' to something else
    # stop_ref changes
    # TODO: stop_ref changes to the NEXT stop on the route (not just any stop)

    departure = true
    departure = false if new_vehicle_position.vehicle_ref != old_vehicle_position.vehicle_ref
    departure = false if old_vehicle_position.arrival_text != "at stop"
    departure = false if new_vehicle_position.stop_ref == old_vehicle_position.stop_ref

    departure
  end

  def self.grab_all_by_line
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

    puts "#{count} HistoricalDepartures created."

  end

  def self.grab_all
    existing_count = HistoricalDeparture.all.count
    puts "round 1"
    response = HTTParty.get(ApplicationController::ALL_VEHICLES_URL)
    # byebug
    vehicle_positions_a = extract_vehicle_positions(response)
    puts "waiting"
    sleep(33)
    puts "round 2"
    response = HTTParty.get(ApplicationController::ALL_VEHICLES_URL)
    vehicle_positions_b = extract_vehicle_positions(response)

    puts "extracting"
    scrape_departures(vehicle_positions_a, vehicle_positions_b)

    new_count = HistoricalDeparture.all.count - existing_count
    puts "#{new_count} historical departures created."
  end

  def self.grab_all_smart
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
  end

end
