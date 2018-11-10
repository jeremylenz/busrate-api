class VehiclePosition < ApplicationRecord

  belongs_to :vehicle
  belongs_to :bus_line
  
end
