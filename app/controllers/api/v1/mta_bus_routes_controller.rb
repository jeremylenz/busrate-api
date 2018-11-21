class Api::V1::MtaBusRoutesController < ApplicationController

  # This controller handles all the MTA API calls and data pass-thru

  def mta_bus_list
    memoized_bus_list = MtaBusLineList.latest
    if memoized_bus_list.blank? || memoized_bus_list.created_at < 21.days.ago
      logger.info "Fetching new bus list from MTA API"
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

    response = HTTParty.get(url)

    if response.code == 200
      # Get vehicle position data to use for our own purposes before passing thru the MTA response
      data = response['Siri']['ServiceDelivery']['StopMonitoringDelivery'][0]['MonitoredStopVisit']
      timestamp = response['Siri']['ServiceDelivery']['ResponseTimestamp']
      new_vehicle_positions = data.map { |monitored_stop_visit| VehiclePosition.extract_single(monitored_stop_visit, timestamp) }.compact
      HistoricalDeparture.fast_insert_objects('vehicle_positions', new_vehicle_positions)
      render json: response
    else
      render json: {error: 'MTA API returned no data', response: JSON.parse(response.body)}, status: response.code
    end

  end

  def vehicles_for_route
    route_id = params[:id]
    url_addon = ERB::Util.url_encode(route_id)
    url = LIST_OF_VEHICLES_URL + "&LineRef=" + url_addon

    response = HTTParty.get(url)

    if response.code == 200
      render json: response
    else
      render json: {error: 'MTA API returned no data', response: JSON.parse(response.body)}, status: response.code
    end
  end

end
