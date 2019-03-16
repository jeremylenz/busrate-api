class Api::V1::HistoricalDeparturesController < ApplicationController

  def index
    line_ref_param = request.url.split("=")[1]
    if line_ref_param.present?
      # Given a Select Bus Service lineRef such as "MTA NYCT_M15+", which comes in as "MTA%20NYCT_M15+",
      # this is the only way I've found to remove the %20 but not remove the +.
      # Rails sets params[:lineRef] to "MTA NYCT_M15 " (with a space instead of the +) which won't work.
      line_ref_param = line_ref_param.gsub(/%20/," ")
    end

    line_ref = BusLine.find_by(line_ref: line_ref_param)&.line_ref
    stop_ref = BusStop.find_by(stop_ref: params[:bus_stop_id])&.stop_ref

    if params[:bus_stop_id].blank? || params[:lineRef].blank?
      render json: {error: "You must specify both a stop ref and a lineRef"}, status: 422
      return
    elsif stop_ref.blank?
      render json: {error: "stop_ref #{params[:bus_stop_id]} not found"}, status: 422
      return
    elsif line_ref.blank?
      render json: {error: "line_ref #{params[:line_ref]} not found"}, status: 422
      return
    end


    @historical_departures = HistoricalDeparture.for_route_and_stop(line_ref, stop_ref)
    logger.info "HistoricalDepartures controller: preventing duplicates..."
    HistoricalDeparture.prevent_duplicates([], @historical_departures) # when this gets too slow we can just do it for recents and previous, not all
    @historical_departures.reload

    start_time = Time.current

    # Update any headways we may be about to display to the user.
    # Don't want any nil headways to show up on the front end.
    # Only update headways for the past 8 days (691_200 seconds) -- too slow otherwise
    headways_to_update = @historical_departures.newer_than(691_200).order(departure_time: :desc)
    headway_update_needed = (headways_to_update.where(headway: nil).count > 0)
    if headway_update_needed
      headways_updated = HistoricalDeparture.process_batch(headways_to_update)[:successful_count]
      @historical_departures.reload
      logger.info "historical_departures_controller: Updated #{headways_updated} headways in #{(Time.current - start_time).round(2)} seconds"
    else
      logger.info "historical_departures_controller: headway recalc not needed; decision time #{(Time.current - start_time).round(2)} seconds"
    end

    # get most recent 8
    today = Time.zone.now.in_time_zone("EST").strftime('%A')
    recents = @historical_departures.first(8)
    current_headway = Time.zone.now.in_time_zone("EST") - @historical_departures.first.departure_time
    logger.info "current_headway: #{current_headway}"
    recents_rating = HistoricalDeparture.rating(recents, 8, current_headway)
    overall_rating = HistoricalDeparture.rating(@historical_departures, 8)
    weekday_rating = HistoricalDeparture.rating(@historical_departures.weekdays_only, 8)
    weekend_rating = HistoricalDeparture.rating(@historical_departures.weekends_only, 8)
    morning_rush_hour_rating = HistoricalDeparture.rating(@historical_departures.morning_rush_hours_only, 8)
    evening_rush_hour_rating = HistoricalDeparture.rating(@historical_departures.evening_rush_hours_only, 8)

    if today == "Monday"
      compare_time = 72.hours.ago
      prev_text = "Friday"
    elsif today == "Sunday" || today == "Saturday"
      compare_time = 7.days.ago
      prev_text = "Last #{today}"
    else
      compare_time = 24.hours.ago
      prev_text = "Yesterday"
    end

    compare_time += 10.minutes # how late was the bus this time yesterday?

    prev_departures = @historical_departures.where(['departure_time < ?', compare_time]).first(8)
    prev_departures_rating = HistoricalDeparture.rating(prev_departures, 8)

    today_times = recents.map { |hd| hd.departure_time }
    prev_times = prev_departures.map { |hd| hd.departure_time }

    render json: {
      line_ref: line_ref,
      stop_ref: stop_ref,
      recents: recents,
      recents_rating: recents_rating,
      recent_departure_times: today_times,
      prev_departures: prev_departures,
      prev_departures_rating: prev_departures_rating,
      prev_departure_times: prev_times,
      prev_departure_text: prev_text,
      overall_rating: overall_rating,
      weekday_rating: weekday_rating,
      weekend_rating: weekend_rating,
      morning_rush_hour_rating: morning_rush_hour_rating,
      evening_rush_hour_rating: evening_rush_hour_rating,
      response_timestamp: Time.zone.now.in_time_zone("EST"),
    }

  end

end
