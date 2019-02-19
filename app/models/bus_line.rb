class BusLine < ApplicationRecord

  has_many :vehicle_positions
  validates_presence_of :line_ref
  validates_uniqueness_of :line_ref

  # Trip view and trip sequence should be same format
  # must specify destination_ref
  # should return only ONE matching_departures list with metadata
  # maybe write method to choose destination
  # aggregate_trip_view will just be a list of trip views in the same format as trip_view

  @@ordered_stop_refs_cache = {}

  def self.pick_direction_ref(line_ref, stop_ref)
    bus_line = self.find_by(line_ref: line_ref)
    stop_lists = bus_line.ordered_stop_refs
    # Return either 0 or 1 depending on which stop_list the stop_ref is found in.
    # If neither, find_index will return nil.
    stop_lists.find_index do |stop_list|
      stop_list[:stop_refs].include?(stop_ref)
    end
  end

  def self.trip_view(trip_identifier, line_ref, vehicle_ref, direction_ref)
    # Given a trip identifier, line_ref, and vehicle_ref,
    # return the first matching departure time for each stop along the route.
    # May show departures from several different trips.

    # Sample snippet from result[:destinations][0][:matching_departures]:
    # {:stop_ref=>"MTA_803019", :departure_time=>Sat, 16 Feb 2019 06:56:07 UTC +00:00}
    # {:stop_ref=>"MTA_401664", :departure_time=>Sat, 16 Feb 2019 06:58:46 UTC +00:00}
    # {:stop_ref=>"MTA_401665", :departure_time=>Sat, 16 Feb 2019 04:40:10 UTC +00:00}
    # {:stop_ref=>"MTA_401666", :departure_time=>Sat, 16 Feb 2019 06:59:49 UTC +00:00}
    # {:stop_ref=>"MTA_401667", :departure_time=>nil}
    # {:stop_ref=>"MTA_404850", :departure_time=>Sat, 16 Feb 2019 07:01:24 UTC +00:00}

    departures = HistoricalDeparture.for_line_and_trip(line_ref, trip_identifier)

    self.build_trip_view(departures, line_ref, vehicle_ref, direction_ref, trip_identifier)
  end

  def self.build_trip_view(departures, line_ref, vehicle_ref, direction_ref, trip_identifier)

    bus_line = self.find_by(line_ref: line_ref)
    return if bus_line.blank? || direction_ref.blank? || direction_ref > 1
    stop_list = bus_line.ordered_stop_refs(direction_ref)

    {
      trip_identifier: trip_identifier,
      line_ref: line_ref,
      vehicle_ref: vehicle_ref,
      direction_ref: direction_ref,
      matching_departures: self.build_matching_departures_hash(stop_list, vehicle_ref, departures),
    }

  rescue NoMethodError
    return nil
  end

  def self.aggregate_trip_view(departures)
    # Sort departures by trip identifier, and return a list of trip views
    # in the same format as self.trip_view
    start_time = Time.current
    db_time = 0.0
    sr_time = 0.0
    sorted_departures = departures.order("block_ref DESC, dated_vehicle_journey_ref DESC, vehicle_ref")
    result = []

    current_batch = []
    current_batch_trip_identifier = nil

    sorted_departures.each_instance do |current_departure|
      if current_batch_trip_identifier.blank?
        # we are the beginning of a new batch
        current_batch_trip_identifier = current_departure.trip_identifier
      end
      if current_departure.trip_identifier == current_batch_trip_identifier
        # Add departures to current_batch until current_batch_trip_identifier no longer matches
        current_batch << current_departure
        next
      else
        # Process batch and update stats
        print "#{current_batch_trip_identifier} | current batch length: #{current_batch.length}       \r"

        directions = current_batch.map { |d| d.direction_ref }
        if directions.length > directions.uniq.length
          logger.info directions.inspect
        end

        sample_departure = current_batch.first
        if sample_departure.present?
          vehicle_ref = current_batch.first.vehicle_ref
          line_ref = current_batch.first.line_ref
          direction_ref = current_batch.first.direction_ref || 0

          db_start = Time.current
          bus_line = BusLine.find_by(line_ref: line_ref)
          db_time += (Time.current - db_start)

          sr_start = Time.current
          stop_refs = bus_line.ordered_stop_refs(direction_ref)
          stop_refs = bus_line.ordered_stop_refs(0) if stop_refs.blank? # The B74 has only one direction_ref but the MTA uses 1 and not 0! [eye_roll_emoji]
          sr_time += (Time.current - sr_start)

          if stop_refs.blank?
            logger.info "Can't find ordered_stop_refs for #{line_ref}, direction #{direction_ref}"
          end

          result << {
            trip_identifier: current_batch_trip_identifier,
            line_ref: line_ref,
            vehicle_ref: vehicle_ref,
            direction_ref: direction_ref,
            matching_departures: build_matching_departures_hash(stop_refs, vehicle_ref, current_batch),
          }
        end

        # reset
        current_batch_trip_identifier = current_departure.trip_identifier
        current_batch = []
      end
    end
    puts # because of the print after else on 79
    logger.info "aggregate_trip_view complete in #{(Time.current - start_time).round(2)} seconds"
    logger.info "including #{db_time.round(2)} seconds looking up BusLines"
    logger.info "including #{sr_time.round(2)} seconds looking up ordered_stop_refs"
    result
  end

  def self.build_matching_departures_hash(stop_refs, vehicle_ref, departures)
    # Returns an array. Ha.
    return unless stop_refs.present?
    stop_refs.map do |stop_ref|
      if departures.class == ActiveRecord::Relation
        matching_departure = departures.where(
          stop_ref: stop_ref,
          vehicle_ref: vehicle_ref
        ).order(created_at: :desc).first
      else
        # If departures is a regular array, it's an array of HistoricalDepartures passed in from aggregate_trip_view
        matching_departure = departures.find { |dep| dep.stop_ref == stop_ref && dep.vehicle_ref == vehicle_ref }
      end
      if matching_departure.present?
        {
          stop_ref: matching_departure.stop_ref,
          departure_time: matching_departure.departure_time,
          direction_ref: matching_departure.direction_ref,
        }
      else
        {
          stop_ref: stop_ref,
          departure_time: nil,
        }
      end
    end
  end

  def self.trip_sequence(trip_view, key_stop_ref)
    # Take a trip_view and try to determine
    # which departures are from the same vehicle trip.
    # Thus, we will know which departures we need to interpolate.

    trip_identifier = trip_view[:trip_identifier]
    line_ref = trip_view[:line_ref]
    vehicle_ref = trip_view[:vehicle_ref]
    direction_ref = trip_view[:direction_ref]

    result = []
    key_reached = false
    prev_departure_time = nil

    trip_view[:matching_departures].each do |dep_object|
      # If we haven't reached the key_stop_ref yet, ignore the element
      if dep_object[:stop_ref] == key_stop_ref
        prev_departure_time = dep_object[:departure_time]
        key_reached = true
      end
      next unless key_reached

      # Output the departure time if valid (part of a trip sequence), nil if not.
      # A departure is considered part of a trip sequence if it is after the previous departure,
      # but not more than 20 minutes after.

      if dep_object[:departure_time].present? && prev_departure_time.present?
        departure_time_valid = true
        travel_time_from_prev_stop = (dep_object[:departure_time] - prev_departure_time)
        departure_time_valid = false if travel_time_from_prev_stop < 0
        departure_time_valid = false if travel_time_from_prev_stop > 20.minutes
      else
        departure_time_valid = false
      end

      if prev_departure_time.blank? || departure_time_valid
        # We found a matching departure for this vehicle, trip identifier, and stop.
        result << dep_object
        prev_departure_time = dep_object[:departure_time]
      else
        # The vehicle may have skipped over the stop.
        result << {
          stop_ref: dep_object[:stop_ref],
          departure_time: nil,
        }
      end

    end

    {
      trip_identifier: trip_identifier,
      line_ref: line_ref,
      vehicle_ref: vehicle_ref,
      direction_ref: direction_ref,
      trip_sequence: result,
    }

  end

  def self.all_trip_sequences(trip_view)
    # self.trip_sequence can return different vehicle trips depending on key_stop_ref.
    # Return all possible, useful trip sequences that can be gleaned from a given trip view.

    result = []
    unique_vehicle_trips = []
    return if trip_view.blank? || trip_view[:matching_departures].blank?
    matching_departures = trip_view[:matching_departures]
    stop_refs = matching_departures.map { |d| d[:stop_ref] }

    stop_refs.each do |stop_ref|
      # make set from trip sequence, trying stop_ref as the key_stop_ref
      current_trip_sequence = trip_sequence(trip_view, stop_ref)
      sequence_set = Set.new(current_trip_sequence[:trip_sequence])
      # see if it's a subset of any of the unique vehicle trips
      if unique_vehicle_trips.any? { |unique_vehicle_trip| sequence_set.subset?(unique_vehicle_trip) }
        # if it's a subset, throw it away
        next
      else
        # if it's new, add to results
        unique_vehicle_trips << sequence_set
        result << current_trip_sequence
      end
    end

    # disregard results where we don't have a departure for at least half the stops
    min_length = stop_refs.length / 2

    result.select { |trip_sequence| trip_sequence[:trip_sequence].count { |ts| ts[:departure_time].present? } >= min_length }
  end

  def self.interpolate_timestamps(start_time, end_time, num_of_results = 1)
    result = []
    return [] if num_of_results < 1 || num_of_results > 5
    total_time = end_time - start_time
    num_of_time_chunks = num_of_results + 1
    interval = total_time / num_of_time_chunks

    current_timestamp = start_time
    (1..num_of_results).each do |offset|
      result << start_time + (offset * interval)
    end

    result
  end

  def self.interpolate_trip_sequence(trip_sequence)
    # Pass in the result of self.trip_sequence
    # IMPORTANT: Assumes this list is already sanitized!  Don't pass in a raw trip_view.
    # Returns the same object, but with interpolated departure times added where they were missing.

    # Shave off nil values from the beginning
    result = trip_sequence[:trip_sequence].drop_while { |d| d[:departure_time].blank? }
    # Shave off nil values from the end
    result = result.reverse.drop_while { |d| d[:departure_time].blank? }.reverse

    start_time = nil
    num_interpolated_timestamps = 0
    end_time = nil
    indices_to_update = []

    result.each_with_index do |dep_object, idx|
      current_timestamp = dep_object[:departure_time]
      if current_timestamp.nil?
        num_interpolated_timestamps += 1
        indices_to_update << idx
        # check if start_time is populated
      elsif start_time.nil?
        # set the start time
        start_time = current_timestamp
      elsif end_time.nil?
        end_time = current_timestamp
        # do the interpolation
        interpolated_timestamps = self.interpolate_timestamps(start_time, end_time, num_interpolated_timestamps)
        # logger.info "Interpolated: #{interpolated_timestamps}"
        # logger.info "indices_to_update: #{indices_to_update}"
        indices_to_update.each_with_index do |result_idx, interpolated_timestamps_idx|
          result[result_idx][:interpolated_departure_time] = interpolated_timestamps[interpolated_timestamps_idx]
        end
        # logger.info "Current: #{current_timestamp} | start_time: #{start_time} | end_time: #{end_time} | num_interpolated_timestamps: #{num_interpolated_timestamps}"
        # reset the variables
        start_time = current_timestamp
        num_interpolated_timestamps = 0
        end_time = nil
        indices_to_update = []
      end
    end

    {
      trip_identifier: trip_sequence[:trip_identifier],
      line_ref: trip_sequence[:line_ref],
      vehicle_ref: trip_sequence[:vehicle_ref],
      direction_ref: trip_sequence[:direction_ref],
      interpolated_trip_sequence: result,
    }
  end

  def self.interpolated_departures_to_create(interpolated_trip_sequence)
    skinny_objects = interpolated_trip_sequence[:interpolated_trip_sequence].select { |dep_obj| dep_obj[:interpolated_departure_time].present? }
    skinny_objects.map do |skinny|
      bus_stop = BusStop.find_by(stop_ref: skinny[:stop_ref])
      next if bus_stop.blank?

      {
        bus_stop_id: bus_stop.id,
        stop_ref: skinny[:stop_ref],
        line_ref: interpolated_trip_sequence[:line_ref],
        direction_ref: interpolated_trip_sequence[:direction_ref],
        vehicle_ref: interpolated_trip_sequence[:vehicle_ref],
        block_ref: interpolated_trip_sequence[:trip_identifier],
        dated_vehicle_journey_ref: nil,
        departure_time: skinny[:interpolated_departure_time],
        interpolated: true,
      }
    end
  end

  def ordered_stop_refs(direction_ref = nil)

    existing_data_in_memory = @@ordered_stop_refs_cache[self.line_ref.to_sym]
    # Return cached result if present
    if existing_data_in_memory
      if direction_ref.present?
        # logger.info "returning cached ordered_stop_refs"
        return existing_data_in_memory[direction_ref][:stop_refs]
      else
        return existing_data_in_memory
      end
    end
    # logger.info "getting new ordered_stop_refs"

    if self.updated_at < 21.days.ago || self.stop_refs_response.blank?
      logger.info "Refreshing stop_refs for #{self.line_ref}"
      self.update_stop_refs
    end

    return nil if self.stop_refs_response.nil?
    response = JSON.parse(self.stop_refs_response)
    stop_groups_data = response['entry']['stopGroupings'][0]['stopGroups']

    result = stop_groups_data.map do |stop_group|
      destination_name = stop_group['name']['name']
      stop_refs = stop_group['stopIds']
      {
        destination_name: destination_name,
        stop_refs: stop_refs,
      }
    end

    return if result.blank?

    # cache the result for next lookup
    @@ordered_stop_refs_cache[self.line_ref.to_sym] = result

    if direction_ref.present?
      result[direction_ref][:stop_refs]
    else
      result
    end

  rescue NoMethodError
    return nil
  end

  def next_stop_ref(stop_ref, direction_ref)
    stop_refs = ordered_stop_refs(direction_ref)
    this_stop_idx = stop_refs.find_index(stop_ref)
    return nil if this_stop_idx.blank? || this_stop_idx >= stop_refs.length - 1
    stop_refs[this_stop_idx + 1]
  end

  def previous_stop_ref(stop_ref, direction_ref)
    stop_refs = ordered_stop_refs(direction_ref)
    this_stop_idx = stop_refs.find_index(stop_ref)
    return nil if this_stop_idx.blank? || this_stop_idx == 0
    stop_refs[this_stop_idx - 1]
  end

  def first_stop_ref(direction_ref)
    stop_refs = ordered_stop_refs(direction_ref)
    stop_refs.first
  end

  def last_stop_ref(direction_ref)
    stop_refs = ordered_stop_refs(direction_ref)
    stop_refs.last
  end

  def update_stop_refs
    line_ref = self.line_ref
    base_url = "http://bustime.mta.info/api/where/stops-for-route/"
    url_addon = "#{line_ref}.json?key=#{ApplicationController::MTA_BUS_API_KEY}&includePolylines=false&version=2"
    url_addon = ERB::Util.url_encode(url_addon)
    url_addon = base_url + url_addon
    response = HTTParty.get(url_addon)

    if response.code == 200
      self.update(
        stop_refs_response: JSON.generate(response['data'])
      )
    end
  end

end
