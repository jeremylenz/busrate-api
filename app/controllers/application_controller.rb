class ApplicationController < ActionController::API

MTA_BUS_API_KEY = Rails.application.credentials[:mta][:api_key]

LIST_OF_NYCT_BUS_ROUTES_URL = "http://bustime.mta.info/api/where/routes-for-agency/MTA%20NYCT.json?key=#{MTA_BUS_API_KEY}"
LIST_OF_MTA_BUS_ROUTES_URL = "http://bustime.mta.info/api/where/routes-for-agency/MTABC.json?key=#{MTA_BUS_API_KEY}"
MTALINES_URL = "http://bustime.mta.info/api/where/routes-for-agency/MTA.json?key=#{MTA_BUS_API_KEY}"
LIST_OF_VEHICLES_URL = "http://bustime.mta.info/api/siri/vehicle-monitoring.json?key=#{MTA_BUS_API_KEY}&version=2&OperatorRef=MTA"
LIST_OF_AGENCIES_URL = "http://bustime.mta.info/api/where/agencies-with-coverage.json?key=#{MTA_BUS_API_KEY}"
VEHICLES_FOR_STOP_URL = "http://bustime.mta.info/api/siri/stop-monitoring.json?key=#{MTA_BUS_API_KEY}&version=2&OperatorRef=MTA"


end
