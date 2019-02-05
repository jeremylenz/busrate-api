class Api::V1::StatsController < ApplicationController

  include ActionView::Helpers::NumberHelper

  def index
    @mta_api_call_records_count = MtaApiCallRecord.where(['created_at > ?', 300.seconds.ago]).count
    @bus_line_count = BusLine.all.count
    @bus_stop_count = BusStop.all.count

    # @historical_departure_count = HistoricalDeparture.all.count
    # doing this estimate instead of the above - it's way faster
    sql = "SELECT reltuples::BIGINT AS estimate FROM pg_class WHERE relname='historical_departures';"
    @historical_departure_count = ActiveRecord::Base.connection.execute(sql).first["estimate"]

    @historical_departure_recent_count = HistoricalDeparture.newer_than(1200).count / 20
    @historical_departures_per_day = @historical_departure_recent_count * 60 * 24
    @headways_recent_count = HistoricalDeparture.newer_than(1200).where.not(headway: nil)
    @nil_headways_recent_count = HistoricalDeparture.newer_than(1200).where(headway: nil)

    @vehicle_position_count = VehiclePosition.all.count
    @vehicle_position_recent_count = VehiclePosition.newer_than(1200).count / 20
    @vehicle_count = Vehicle.all.count

    if @mta_api_call_records_count > 0
      @avg_vehicle_positions_per_api_call = @vehicle_position_recent_count * 5 / @mta_api_call_records_count
      @avg_departures_per_api_call = @historical_departure_recent_count * 5 / @mta_api_call_records_count
    end

    response = {
      mta_api_all_vehicles_calls: @mta_api_call_records_count,
      historical_departures: number_with_delimiter(@historical_departure_count, delimiter: ','),
      historical_departures_per_minute: @historical_departure_recent_count,
      historical_departures_per_day: @historical_departures_per_day,
      last_20_min_headways_count: @headways_recent_count,
      last_20_min_nil_headways: @nil_headways_recent_count,
      vehicle_positions: @vehicle_position_count,
      vehicle_positions_per_minute: @vehicle_position_recent_count,
      bus_lines: @bus_line_count,
      bus_stops: @bus_stop_count,
      vehicles: @vehicle_count,
      avg_vehicle_positions_per_api_call: @avg_vehicle_positions_per_api_call,
      avg_departures_per_api_call: @avg_departures_per_api_call,
      response_timestamp: Time.zone.now.in_time_zone("EST"),
    }
    render json: response
  end

  def ping
    if Time.current.seconds_since_midnight.to_i < 21_600 # if it's before 6 am, skip this
      logger.info "Skipping heroku ping"
      render json: {response: "Skipping heroku ping; it's before 6 am"}
      return
    end

    url = URI.encode("http://busrate.herokuapp.com/")
    response = HTTParty.get(url)
    if response.code == 200
      logger.info "Pinged heroku app; OK"
      render json: {response: "OK"}
    else
      logger.error "Pinged heroku app and received HTTP code #{response.code}"
      render json: {response: response}
    end
  end
end
