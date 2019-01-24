class BusStop < ApplicationRecord

  has_many :vehicle_positions
  has_many :historical_departures
  validates_presence_of :stop_ref
  validates_uniqueness_of :stop_ref

  def self.find_and_remove_duplicates
    # Find bus stops with duplicate stop_ref (shouldn't happen)
    # Assign all departures to one of them and destroy the other

    BusStop.all.each do |bus_stop_a|
      print "Processing #{bus_stop_a.id}\r"
      $stdout.flush

      next if bus_stop.valid?
      # do we have a duplicate?
      # if so, find the twin
      bus_stop_b = BusStop.where(stop_ref: bus_stop_a.stop_ref).where.not(id: bus_stop_a.id).first
      if bus_stop_b.blank?
        logger.info "Couldn't find duplicate bus stop for #{bus_stop_a.id}"
        logger.info "Errors: #{bus_stop_a.errors.full_messages.join("; ")}"
        next
      end
      # decide which one to keep
      logger.info "Deciding which one to keep"
      if bus_stop_a.historical_departures.count > bus_stop_b.historical_departures.count
        keeper = bus_stop_a
        bad_bus_stop = bus_stop_b
        logger.info "keeping #{keeper.id}, bus_stop_a"
      else
        keeper = bus_stop_b
        bad_bus_stop = bus_stop_a
        logger.info "keeping #{keeper.id}, bus_stop_b"
      end
      # migrate the data
      logger.info "Migrating vehicle positions"
      bad_bus_stop.vehicle_positions.each do |vehicle_position|
        vehicle_position.update(bus_stop: keeper)
      end
      logger.info "Migrating historical departures"
      bad_bus_stop.historical_departures.each do |historical_departure|
        historical_departure.update(bus_stop: keeper)
      end
      logger.info "Destroying BusStop #{bad_bus_stop.id}"
      bad_bus_stop.destroy
    end
  end

  def self.clean_up(limit)
    # Before validations were added, a bus stop got created with a nil stop_ref and departures got assigned to it.  Need this to clean it up.
    start_time = Time.current
    logger.info "Cleaning up bus stops..."
    bad_bus_stop = self.where(stop_ref: nil).first
    if bad_bus_stop.blank?
      logger.info "No bus stops found with nil stop_ref :)"
      return
    end
    logger.info "BusStop with nil stop_ref: #{bad_bus_stop.id}"
    ids_to_purge = []
    successful_count = 0
    purge_count = 0
    error_count = 0

    hds = bad_bus_stop.historical_departures.limit(limit).each_instance do |hd|
      if hd.stop_ref.blank?
        purge_count += 1
        ids_to_purge << hd.id
      end
      real_bus_stop = BusStop.find_by(stop_ref: hd.stop_ref)
      if real_bus_stop.blank?
        hd.errors << "Couldn't find bus stop with stop_ref #{hd.stop_ref}"
      end
      # logger.info "#{[hd.id, hd.stop_ref, hd.bus_stop_id]} --> #{[hd.id, real_bus_stop.stop_ref, real_bus_stop.id]}"
      hd.update(
        bus_stop_id: real_bus_stop.id
      )
      if hd.errors.any?
        error_count += 1
        logger.info "Error updating historical departure #{hd.id} - #{hd.errors.full_messages.join("; ")}"
      else
        successful_count += 1
      end
      print "successful_count: #{successful_count} | purge_count: #{purge_count} | error_count: #{error_count}  \r"
    end # of each_instance
    puts

    # purge departures with no stop_ref
    if purge_count > 0
      logger.info "Purging departures..."
      ids_to_purge.uniq!
      HistoricalDeparture.delete(ids_to_purge.take(65_535))
      logger.info "#{purge_count} departures purged"
    end

    logger.info "#{successful_count} departures moved"
    logger.info "#{error_count} departures not updated due to errors" if error_count > 0
    logger.info "#{bad_bus_stop.historical_departures.count} departures remaining"
    logger.info "clean_up complete in #{(Time.current - start_time).round(2)} seconds"
  end

end
