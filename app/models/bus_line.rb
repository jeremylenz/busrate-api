class BusLine < ApplicationRecord

  has_many :vehicle_positions
  validates_presence_of :line_ref
  validates_uniqueness_of :line_ref

  def self.trip_view(trip_identifier, line_ref, vehicle_ref)
    # Given a trip identifier, line_ref, and vehicle_ref,
    # return the first matching departure time for each stop along the route.

    bus_line = self.find_by(line_ref: line_ref)
    return if bus_line.blank?

    stop_lists = bus_line.ordered_stop_refs # [direction_a_stops, direction_b_stops]
    departures = self.departures_for_line_and_trip(line_ref, trip_identifier)
    result = {
      trip_identifier: trip_identifier,
      line_ref: line_ref,
      vehicle_ref: vehicle_ref,
      destinations: [],
    }

    stop_lists.each do |stop_list|
      result[:destinations] << {
        destination_name: stop_list[:destination_name],
        matching_departures: stop_list[:stop_refs].map do |stop_ref|
          matching_departure = departures.where(
            stop_ref: stop_ref,
            vehicle_ref: vehicle_ref
          ).order(created_at: :desc).first
          if matching_departure.present?
            {
              stop_ref: matching_departure.stop_ref,
              departure_time: matching_departure.departure_time,
            }
          else
            {
              stop_ref: stop_ref,
              departure_time: nil,
            }
          end
        end
      }

    end
    result

  rescue NoMethodError
    return nil
  end

  def self.trip_sequence(dep_list_obj, key_stop_ref)
    # Take a list of matching departures from self.trip_view
    # Try to determine which departures are from the same vehicle trip
    # Thus, we will know which departures we need to interpolate

    result = []
    key_reached = false
    prev_departure_time = nil

    dep_list_obj.each do |dep_object|
      # If we haven't reached the key_stop_ref yet, ignore the element
      if dep_object[:stop_ref] == key_stop_ref
        prev_departure_time = dep_object[:departure_time]
        key_reached = true
      end
      next unless key_reached

      # Output the departure time if valid, nil if not.
      # A departure is considered valid if it is after the previous departure, but
      # not more than 20 minutes after.
      if dep_object[:departure_time].present?
        travel_time_from_prev_stop = (dep_object[:departure_time] - prev_departure_time)
      else
        travel_time_from_prev_stop = 99.minutes
      end

      if prev_departure_time.blank? ||  travel_time_from_prev_stop < 20.minutes
        result << dep_object
        prev_departure_time = dep_object[:departure_time]
      else
        result << {
          stop_ref: dep_object[:stop_ref],
          departure_time: nil,
        }
      end

    end

    result
  end

  def self.departures_for_line_and_trip(line_ref, trip_identifier)
    departures = HistoricalDeparture.where(
      ["block_ref = ? OR dated_vehicle_journey_ref = ?", trip_identifier, trip_identifier]
    ).where(line_ref: line_ref)
  end

  def ordered_stop_refs
    return nil if self.stop_refs_response.nil?

    if self.updated_at < 21.days.ago
      logger.info "Refreshing stop_refs for #{self.line_ref}"
      self.update_stop_refs
    end

    response = JSON.parse(self.stop_refs_response)
    stop_groups_data = response['entry']['stopGroupings'][0]['stopGroups']

    stop_groups_data.map do |stop_group|
      destination_name = stop_group['name']['name']
      stop_refs = stop_group['stopIds']
      {
        destination_name: destination_name,
        stop_refs: stop_refs,
      }
    end
  end

  def update_stop_refs
    line_ref = self.line_ref
    base_url = "http://bustime.mta.info/api/where/stops-for-route/"
    url_addon = "#{line_ref}.json?key=#{ApplicationController::MTA_BUS_API_KEY}&includePolylines=false&version=2"
    url_addon = ERB::Util.url_encode(url_addon)
    url_addon = base_url + url_addon
    response = HTTParty.get(url_addon)

    if response.code == 200
      self.update(
        stop_refs_response: JSON.generate(response['data'])
      )
    end
  end

end
