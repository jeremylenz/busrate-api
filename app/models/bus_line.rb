class BusLine < ApplicationRecord

  has_many :vehicle_positions
  validates_presence_of :line_ref
  validates_uniqueness_of :line_ref


end
