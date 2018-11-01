Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do

      get 'routes/mta', to: 'bus_routes#mta_bus_list'


    end
  end


  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html
end
