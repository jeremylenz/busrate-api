class BusStop < ApplicationRecord

  has_many :vehicle_positions
  has_many :historical_departures
  validates_presence_of :stop_ref
  validates_uniqueness_of :stop_ref

end
