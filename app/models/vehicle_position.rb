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
    records_to_purge = self.older_than(seconds).ids.take(65_535)
    logger.info "Purging #{records_to_purge.length} VehiclePositions"
    self.delete(records_to_purge)
    logger.info "#{VehiclePosition.all.count} VehiclePositions remaining in database"
  end

  def self.is_departure?(old_vehicle_position, new_vehicle_position)
    return false if old_vehicle_position.blank? || new_vehicle_position.blank?
    # If all of the following rules apply, we consider it a departure:
    # vehicle_ref is the same
    # arrival_text for old_vehicle_position is 'at stop'
    # the two vehicle positions are less than 90 seconds apart
    # stop_ref changes
    # TODO: stop_ref changes to the NEXT stop on the route (not just any stop)

    return false if new_vehicle_position.vehicle_ref != old_vehicle_position.vehicle_ref
    return false if new_vehicle_position.timestamp - old_vehicle_position.timestamp > 90.seconds
    return false if old_vehicle_position.arrival_text != "at stop"
    return false if new_vehicle_position.stop_ref == old_vehicle_position.stop_ref

    true
  end

  def self.expired_dep?(old_vp, new_vp)
    if new_vp.timestamp - old_vp.timestamp > 90.seconds &&
      new_vp.vehicle_ref == old_vp.vehicle_ref &&
      old_vp.arrival_text == "at_stop" &&
      new_vp.stop_ref != old_vp.stop_ref
      return true
    end
    false
  end

  def self.scrape_all_departures
    existing_count = HistoricalDeparture.all.count
    start_time = Time.current
    departures = []

    vehicle_positions = VehiclePosition.newer_than(240).group_by(&:vehicle_ref)
    # "MTABC_3742"=>[#<VehiclePosition ...>, #<VehiclePosition ...>, #<VehiclePosition ...>]
    logger.info "Filtering #{vehicle_positions.length} vehicles"
    vehicle_positions.delete_if { |k, v| v.length < 2 }
    logger.info "Filtered to #{vehicle_positions.length} vehicles with 2+ positions"
    ids_to_purge = []
    expired_count = 0
    vehicle_positions.each do |line_ref, vp_list|
      sorted_vps = vp_list.sort_by(&:timestamp) # guarantee that the oldest vehicle_position is first

      while sorted_vps.length > 1 do
        # Remove the oldest vehicle position
        old_vehicle_position = sorted_vps.shift
        # Compare it with every other position to see if we can make a departure
        sorted_vps.each do |new_vehicle_position|
          expired_count += 1 if expired_dep?(old_vehicle_position, new_vehicle_position)
          if is_departure?(old_vehicle_position, new_vehicle_position)
            new_departure = {
              stop_ref: new_vehicle_position.stop_ref,
              line_ref: new_vehicle_position.line_ref,
              vehicle_ref: new_vehicle_position.vehicle_ref,
              departure_time: new_vehicle_position.timestamp,
            }
            # Purge these vehicle positions so they can't be used in the future to make duplicate departures
            ids_to_purge << old_vehicle_position.id
            ids_to_purge << new_vehicle_position.id
            departures << new_departure
            break # don't make any additional departures from these two vehicle_positions
          end
        end
      end
    end

    ids_to_purge.uniq!

    HistoricalDeparture::fast_insert_objects('historical_departures', departures.compact.uniq)
    VehiclePosition.delete(ids_to_purge.take(65_535))

    logger.info "!------------- #{HistoricalDeparture.all.count - existing_count} historical departures created -------------!"
    logger.info "Avoided #{departures.compact.length - departures.compact.uniq.length} duplicate departures"
    logger.info "#{expired_count} departures not created because vehicle positions were > 90 seconds apart" unless expired_count == 0
    logger.info "#{HistoricalDeparture.all.count} HistoricalDepartures now in database"
    logger.info "#{ids_to_purge.length} old vehicle positions purged"
    logger.info "scrape_all_departures complete in #{Time.current - start_time} seconds"
    departures

  end

end
