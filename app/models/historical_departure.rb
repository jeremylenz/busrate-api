class HistoricalDeparture < ApplicationRecord

  def self.grab_vehicle_positions(route_id)
    # Get all vehicle positions for a given bus line
    url_addon = ERB::Util.url_encode(route_id)
    url = ApplicationController::LIST_OF_VEHICLES_URL + "&LineRef=" + url_addon
    puts url
    response = HTTParty.get(url)

    # Format the data
    vehicle_activity = response['Siri']['ServiceDelivery']['VehicleMonitoringDelivery'][0]['VehicleActivity']
    timestamp = response['Siri']['ServiceDelivery']['ResponseTimestamp']
    vehicle_positions = vehicle_activity.map do |data|
      vehicle_ref = data['MonitoredVehicleJourney']['VehicleRef']
      line_ref = data['MonitoredVehicleJourney']['LineRef']
      arrival_text = data['MonitoredVehicleJourney']['MonitoredCall']['ArrivalProximityText']
      feet_from_stop = data['MonitoredVehicleJourney']['MonitoredCall']['DistanceFromStop']
      stop_ref = data['MonitoredVehicleJourney']['MonitoredCall']['StopPointRef']

      {
        vehicle_ref: vehicle_ref,
        line_ref: line_ref,
        arrival_text: arrival_text,
        feet_from_stop: feet_from_stop,
        stop_ref: stop_ref,
        timestamp: timestamp,
      }
    end


  end

  def self.scrape_departures(old_vehicle_positions, new_vehicle_positions)
    departures = []
    old_vehicle_positions.each do |old_vehicle_position|
      # find the corresponding new_vehicle_position
      next_position = new_vehicle_positions.find { |new_vehicle_position| new_vehicle_position[:vehicle_ref] == old_vehicle_position[:vehicle_ref] }
      if is_departure?(old_vehicle_position, next_position)
        comparison = {
          old: old_vehicle_position,
          new: next_position,
          departed_at: next_position[:timestamp]
        }
        puts "FOUND DEPARTURE"
        departures << comparison
        HistoricalDeparture.create(
          stop_ref: comparison[:new][:stop_ref],
          line_ref: comparison[:new][:line_ref],
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
    departure = false if new_vehicle_position[:vehicle_ref] != old_vehicle_position[:vehicle_ref]
    departure = false if old_vehicle_position[:arrival_text] != "at stop"
    departure = false if new_vehicle_position[:stop_ref] == old_vehicle_position[:stop_ref]

    departure
  end

  def self.tick(wait)
    puts 'getting first position...'
    pos1 = grab_vehicle_positions("MTABC_Q39")
    at_stop = pos1.select { |pos| pos[:arrival_text] == "at stop" }
    return [] if at_stop.blank?
    sleep(wait)
    puts 'getting second position...'
    pos2 = grab_vehicle_positions("MTABC_Q39")
    deps = scrape_departures(pos1, pos2)

    {
      at_stop: at_stop,
      deps: deps,
    }
  end

end
