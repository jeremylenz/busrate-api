class Vehicle < ApplicationRecord

  validates_uniqueness_of :vehicle_ref
  
end
