class BusStop < ApplicationRecord

  has_many :vehicle_positions
  has_many :historical_departures
  validates_presence_of :stop_ref
  validates_uniqueness_of :stop_ref

  def self.clean_up(limit)
    start_time = Time.current
    logger.info "Cleaning up bus stops..."
    bad_bus_stop = self.where(stop_ref: nil).first
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
