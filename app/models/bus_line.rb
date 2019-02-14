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
    }

    stop_lists.each do |stop_list|
      result[:destination] = stop_list[:destination_name]
      result[:matching_departures] = stop_list[:stop_refs].map do |stop_ref|
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
            trip_identifier: nil,
          }
        end
      end
    end

  rescue NoMethodError
    return nil
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
