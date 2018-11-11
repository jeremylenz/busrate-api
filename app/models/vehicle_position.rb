class VehiclePosition < ApplicationRecord

  belongs_to :vehicle
  belongs_to :bus_line

  scope :at_stop, -> { where(arrival_text: "at stop") }
  scope :older_than, -> (num) { where(["timestamp < ?", num.seconds.ago]) }
  scope :newer_than, -> (num) { where(["timestamp > ?", num.seconds.ago]) }
  scope :active, -> { at_stop.older_than(30).newer_than(120) }

  def latest?
    self == self.vehicle.latest_position
  end

  def self.clean_up
    purge_older_than(240)
  end

  def self.purge_older_than(seconds)
    records_to_purge = self.older_than(seconds).ids
    self.delete(ids)
  end

end
