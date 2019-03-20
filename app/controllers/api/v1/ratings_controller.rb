class Api::V1::RatingsController < ApplicationController

  def show
    line_ref_param = request.url.split("/").last.split("?")[0]
    if line_ref_param.present?
      # Given a Select Bus Service lineRef such as "MTA NYCT_M15+", which comes in as "MTA%20NYCT_M15+",
      # this is the only way I've found to remove the %20 but not remove the +.
      # Rails sets params[:lineRef] to "MTA NYCT_M15 " (with a space instead of the +) which won't work.
      line_ref_param = line_ref_param.gsub(/%20/," ")
    end
    stop_ref_param = params[:stopRef]

    line_ref = BusLine.find_by(line_ref: line_ref_param)&.line_ref

    direction_ref = params[:directionRef]

    if line_ref.blank?
      render json: {error: "line_ref #{line_ref_param} not found"}, status: 422
      return
    end
    unless direction_ref.blank?
      unless [0, 1].include?(direction_ref.to_i)
        render json: {error: "directionRef #{direction_ref} not valid"}, status: 422
        return
      end
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
