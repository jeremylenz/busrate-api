class Api::V1::BusRoutesController < ApplicationController

  def mta_bus_list
    response = HTTParty.get(LIST_OF_MTA_BUS_ROUTES_URL)
    render json: response
  end

end
