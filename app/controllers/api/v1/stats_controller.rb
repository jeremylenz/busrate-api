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
    @headways_recent_count = HistoricalDeparture.newer_than(14_400).where.not(headway: nil).count
    @nil_headways_recent_count = HistoricalDeparture.newer_than(14_400).where(headway: nil).count
    total_headways_recent_count = @headways_recent_count + @nil_headways_recent_count
    @headways_success_rate = number_to_percentage(@headways_recent_count.to_f / total_headways_recent_count.to_f * 100.0, precision: 2)

    @interpolated_recent_count = HistoricalDeparture.newer_than(14_400).interpolated.count
    @interpolated_rate = number_to_percentage(@interpolated_recent_count.to_f / HistoricalDeparture.newer_than(14_400).count.to_f * 100.0, precision: 2)

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
      last_4_hours_headways_count: @headways_recent_count,
      last_4_hours_nil_headways: @nil_headways_recent_count,
      last_4_hours_headways_success: @headways_success_rate,
      last_4_hours_interpolated_count: @interpolated_recent_count,
      last_4_hours_interpolated_rate: @interpolated_rate,
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

  def system_health
    @mta_api_call_records_count = MtaApiCallRecord.where(['created_at > ?', 300.seconds.ago]).count
    @vehicle_position_recent_count = VehiclePosition.newer_than(1200).count / 20
    @vehicle_position_count = VehiclePosition.all.count
    @historical_departure_recent_count = HistoricalDeparture.newer_than(1200).count / 20
    @headways_recent_count = HistoricalDeparture.newer_than(3_600).where.not(headway: nil).count
    @interpolated_recent_count = HistoricalDeparture.newer_than(7_200).interpolated.count
    reasons = []

    healthy = true
    if @mta_api_call_records_count < 5
      healthy = false
      reasons << "Not enough calls to MTA API"
    end
    if @vehicle_position_recent_count < 10
      healthy = false
      reasons << "No vehicle_positions being created"
    end
    # If we've shut down nonessential cron jobs and forgotten to restart them, VehiclePosition.clean_up won't run.
    if @vehicle_position_count > 60_000
      healthy = false
      reasons << "Too many old vehicle_positions in system"
    end
    if @historical_departure_recent_count < 10
      healthy = false
      reasons << "No historical departures are being created"
    end
    if @headways_recent_count < 10
      healthy = false
      reasons << "No headways being added to historical departures"
    end
    if @interpolated_recent_count < 1
      healthy = false
      reasons << "No interpolated departures being created"
    end

    health_check = {
      mta_api_all_vehicles_calls: @mta_api_call_records_count,
      vehicle_positions_per_minute: @vehicle_position_recent_count,
      vehicle_positions: @vehicle_position_count,
      historical_departures_per_minute: @historical_departure_recent_count,
      headways_past_hour: @headways_recent_count,
      interpolated_deps_past_hour: @interpolated_recent_count,
      reasons: reasons,
    }
    logger.info health_check.inspect

    if healthy
      render json: {healthy: true, health_check: health_check}
    else
      render json: {healthy: false, health_check: health_check}, status: 503
    end
  end
end
