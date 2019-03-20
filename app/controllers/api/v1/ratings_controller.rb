class Api::V1::RatingsController < ApplicationController

  def show
    line_ref = params[:id]
    stop_ref = params[:stop_ref]
    direction_ref = params[:direction_ref]

    if line_ref.blank?
      render json: {error: "line_ref #{params[:line_ref]} not found"}, status: 422
      return
    end

    if stop_ref
      # show recent rating for route and stop
      rating = HistoricalDeparture.recent_rating_for_route_and_stop(line_ref, stop_ref)
      render json: {
        line_ref: line_ref,
        stop_ref: stop_ref,
        rating: rating,
      }
    elsif direction_ref
      # show recent rating for route
      rating = HistoricalDeparture.recent_rating_for_route(line_ref, direction_ref)
      render json: {
        line_ref: line_ref,
        direction_ref: direction_ref,
        rating: rating,
      }
    else
      render json: {error: "Must supply either a stop_ref or direction_ref"}, status: 422
    end
  end

end
