class VehiclePosition < ApplicationRecord

  belongs_to :vehicle
  belongs_to :bus_line

  scope :at_stop, -> { where(arrival_text: "at stop") }
  scope :older_than, -> (num) { where(["timestamp < ?", num.seconds.ago]) }
  
end
