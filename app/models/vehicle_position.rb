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
    logger.info "VehiclePosition.clean_up"
    purge_older_than(240)
  end

  def self.purge_older_than(seconds)
    records_to_purge = self.older_than(seconds).ids.take(65_536)
    logger.info "Purging #{records_to_purge.length} VehiclePositions"
    self.delete(records_to_purge)
    logger.info "#{VehiclePosition.all.count} VehiclePositions remaining in database"
  end

  def self.is_departure?(old_vehicle_position, new_vehicle_position)
    return false if old_vehicle_position.blank? || new_vehicle_position.blank?
    # If all of the following rules apply, we consider it a departure:
    # vehicle_ref is the same
    # arrival_text for old_vehicle_position is 'at stop'
    # the two vehicle positions are less than 2 minutes apart
    # stop_ref changes
    # TODO: stop_ref changes to the NEXT stop on the route (not just any stop)

    return false if new_vehicle_position.vehicle_ref != old_vehicle_position.vehicle_ref
    return false if new_vehicle_position.timestamp - old_vehicle_position.timestamp > 2.minutes
    return false if old_vehicle_position.arrival_text != "at stop"
    return false if new_vehicle_position.stop_ref == old_vehicle_position.stop_ref

    true
  end

  def self.scrape_all_departures
    existing_count = HistoricalDeparture.all.count
    start_time = Time.current
    departures = []

    vehicle_positions = VehiclePosition.newer_than(240).group_by(&:vehicle_ref)
    logger.info "Filtering #{vehicle_positions.length} vehicles"
    vehicle_positions.delete_if { |k, v| v.length < 2 }
    logger.info "Filtered to #{vehicle_positions.length} vehicles with 2 positions"
    ids_to_purge = []
    vehicle_positions.each do |line_ref, vp_list|
      sorted_vps = vp_list.sort_by(&:timestamp) # guarantee that old_vehicle_position is on the left
      old_vehicle_position = sorted_vps[0]
      new_vehicle_position = sorted_vps[1]
      if is_departure?(old_vehicle_position, new_vehicle_position)
        ids_to_purge << old_vehicle_position.id
        new_departure = {
          stop_ref: new_vehicle_position.stop_ref,
          line_ref: new_vehicle_position.line_ref,
          vehicle_ref: new_vehicle_position.vehicle_ref,
          departure_time: new_vehicle_position.timestamp,
        }
        departures << new_departure
      end
    end

    logger.info "scrape_all_departures ready for fast inserter after #{Time.current - start_time} seconds"

    HistoricalDeparture::fast_insert_objects('historical_departures', departures.compact)
    VehiclePosition.delete(ids_to_purge.take(65_536))

    logger.info "#{HistoricalDeparture.all.count - existing_count} historical departures created"
    logger.info "#{HistoricalDeparture.all.count} HistoricalDepartures now in database"
    logger.info "#{ids_to_purge.length} old vehicle positions purged"
    logger.info "scrape_all_departures complete in #{Time.current - start_time} seconds"
    departures

  end

end
