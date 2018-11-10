class Api::V1::MtaBusRoutesController < ApplicationController

  # This controller handles all the MTA API calls and data pass-thru

  def mta_bus_list
    memoized_bus_list = MtaBusLineList.latest
    if memoized_bus_list.blank? || memoized_bus_list.created_at < 21.days.ago
    # if memoized_bus_list.blank? || memoized_bus_list.created_at < 1.minute.ago
      logger.info "Fetching new bus list"
      mta = HTTParty.get(LIST_OF_MTA_BUS_ROUTES_URL)
      nyct = HTTParty.get(LIST_OF_NYCT_BUS_ROUTES_URL)
      response = mta

      if response.code == 200 && mta['data'] && nyct['data']
        bus_list = mta['data']['list'] + nyct['data']['list']
        MtaBusLineList.create(
          response: JSON.generate(bus_list)
        )
        render json: bus_list
      else
        render json: {body: {error: 'MTA API returned no data; perhaps API key is incorrect', response: JSON.parse(response.body)}}, status: response.code
      end
    else
      logger.info "Using memoized_bus_list"
      render json: memoized_bus_list.response
    end
  end

  def stop_list_for_route
    route_id = params[:id]
    base_url = "http://bustime.mta.info/api/where/stops-for-route/"
    list_of_stops = "#{route_id}.json?key=#{MTA_BUS_API_KEY}&includePolylines=false&version=2"
    list_of_stops = ERB::Util.url_encode(list_of_stops)
    list_of_stops = base_url + list_of_stops
    puts list_of_stops
    # byebug
    response = HTTParty.get(list_of_stops)

    if response.code == 200
      render json: response
    else
      render json: {error: 'MTA API returned no data', response: JSON.parse(response.body)}, status: response.code
    end
  end

  def vehicles_for_stop
    stop_id = params[:id]
    url_addon = ERB::Util.url_encode(stop_id)
    url = VEHICLES_FOR_STOP_URL + "&MonitoringRef=" + url_addon
    puts url

    response = HTTParty.get(url)

    if response.code == 200
      render json: response
    else
      render json: {error: 'MTA API returned no data', response: JSON.parse(response.body)}, status: response.code
    end

  end

  def vehicles_for_route
    route_id = params[:id]
    url_addon = ERB::Util.url_encode(route_id)
    url = LIST_OF_VEHICLES_URL + "&LineRef=" + url_addon
    puts url

    response = HTTParty.get(url)

    if response.code == 200
      render json: response
    else
      render json: {error: 'MTA API returned no data', response: JSON.parse(response.body)}, status: response.code
    end
  end

end
