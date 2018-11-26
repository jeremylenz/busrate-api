class Api::V1::StatsController < ApplicationController

  include ActionView::Helpers::NumberHelper

  def index
    @mta_api_call_records_count = MtaApiCallRecord.where(['created_at < ?', 150.seconds.ago]).count
    @bus_line_count = BusLine.all.count
    @bus_stop_count = BusStop.all.count
    @historical_departure_count = HistoricalDeparture.all.count
    @historical_departure_recent_count = HistoricalDeparture.newer_than(150).count
    @vehicle_position_count = VehiclePosition.all.count
    @vehicle_position_recent_count = VehiclePosition.newer_than(150).count
    @vehicle_count = Vehicle.all.count

    if @mta_api_call_records_count > 0
      @avg_vehicles_per_api_call = @vehicle_position_recent_count / @mta_api_call_records_count
      @avg_departures_per_api_call = @historical_departure_recent_count / @mta_api_call_records_count
    end
    
    response = {
      mta_api_all_vehicles_calls: @mta_api_call_records_count,
      bus_lines: @bus_line_count,
      bus_stops: @bus_stop_count,
      historical_departures: number_with_delimiter(@historical_departure_count, delimiter: ','),
      historical_departures_last_150_seconds: @historical_departure_recent_count,
      vehicle_positions: @vehicle_position_count,
      vehicle_positions_last_150_seconds: @vehicle_position_recent_count,
      vehicles: @vehicle_count,
      avg_vehicles_per_api_call: @avg_vehicles_per_api_call,
      avg_departures_per_api_call: @avg_departures_per_api_call,
      response_timestamp: Time.zone.now.in_time_zone("EST"),
    }
    render json: response
  end
end
