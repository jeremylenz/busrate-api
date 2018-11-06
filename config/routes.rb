Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do

      get 'mta/routes', to: 'bus_routes#mta_bus_list'
      get 'mta/stoplists/:id', to: 'bus_routes#stop_list_for_route'
      get 'mta/vehicles_for_stop/:id', to: 'bus_routes#vehicles_for_stop'

    end
  end


  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html
end
