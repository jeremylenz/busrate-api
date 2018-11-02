class Api::V1::BusRoutesController < ApplicationController

  def mta_bus_list
    mta = HTTParty.get(LIST_OF_MTA_BUS_ROUTES_URL)
    nyct = HTTParty.get(LIST_OF_NYCT_BUS_ROUTES_URL)

    if response.code == 200 && mta['data'] && nyct['data']
      bus_list = mta['data']['list'] + nyct['data']['list']
      render json: bus_list
    else
      render json: {body: {error: 'MTA API returned no data; perhaps API key is incorrect', body: response.body}}, status: 422
    end
  end

  def show
    route_id = params[:id]
    base_url = "http://bustime.mta.info/api/where/stops-for-route/"
    list_of_stops = "#{route_id}.json?key=#{MTA_BUS_API_KEY}&includePolylines=false&version=2"
    list_of_stops = ERB::Util.url_encode(list_of_stops)
    list_of_stops = base_url + list_of_stops
    puts list_of_stops
    # byebug
    route_data = HTTParty.get(list_of_stops)

    if route_data.code == 200
      render json: route_data
    else
      render json: {error: 'MTA API returned no data', response: JSON.parse(route_data.body)}, status: route_data.code
    end
  end

end
