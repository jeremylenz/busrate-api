# For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html

Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do

      get 'mta/routes', to: 'mta_bus_routes#mta_bus_list'
      get 'mta/stoplists/:id', to: 'mta_bus_routes#stop_list_for_route'
      get 'mta/vehicles_for_stop/:id', to: 'mta_bus_routes#vehicles_for_stop'
      get 'mta/vehicles_for_route/:id', to: 'mta_bus_routes#vehicles_for_route'

      resources :bus_stops, only: [] do
        resources :historical_departures, only: [:index]
      end
      resources :stats, only: [:index]

    end
  end


end
