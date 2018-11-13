class Api::V1::HistoricalDeparturesController < ApplicationController

  def index
    line_ref = BusLine.find_by(line_ref: params[:lineRef])&.line_ref
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

    times = @historical_departures.map { |hd| hd.departure_time }
    render json: {
      line_ref: line_ref,
      stop_ref: stop_ref,
      historical_departures: times,
    }

  end

end
