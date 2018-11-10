class Vehicle < ApplicationRecord

  has_many :vehicle_positions
  validates_uniqueness_of :vehicle_ref

  def latest_position
    self.vehicle_positions.order(timestamp: :desc).first
  end
end
