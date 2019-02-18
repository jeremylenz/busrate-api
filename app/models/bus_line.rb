class BusLine < ApplicationRecord

  has_many :vehicle_positions
  validates_presence_of :line_ref
  validates_uniqueness_of :line_ref

  # Trip view and trip sequence should be same format
  # must specify destination_ref
  # should return only ONE matching_departures list with metadata
  # maybe write method to choose destination
  # aggregate_trip_view will just be a list of trip views in the same format as trip_view

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
    sorted_departures = departures.order("block_ref DESC, dated_vehicle_journey_ref DESC")
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
        current_batch << {
          stop_ref: current_departure.stop_ref,
          departure_time: current_departure.departure_time,
          direction_ref: current_departure.direction_ref,
        }
        next
      else
        # Process batch and update stats
        print "#{current_batch_trip_identifier} | current batch length: #{current_batch.length}   \r"

        sample_departure = current_batch.first
        if sample_departure.present?
          vehicle_ref = current_batch.first.vehicle_ref
          line_ref = current_batch.first.line_ref
          direction_ref = current_batch.first.direction_ref || 0

          bus_line = BusLine.find_by(line_ref: line_ref)
          stop_refs = bus_line.ordered_stop_refs(direction_ref)

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

    result
  end

  def self.build_matching_departures_hash(stop_refs, vehicle_ref, departures)
    stop_refs.map do |stop_ref|
      if departures.class == ActiveRecord::Relation
        matching_departure = departures.where(
          stop_ref: stop_ref,
          vehicle_ref: vehicle_ref
        ).order(created_at: :desc).first
      else
        # If departures is a regular array, it's an array of hashes passed in from aggregate_trip_view
        matching_departure = departures.find { |dep| dep[:stop_ref] == stop_ref && dep[:vehicle_ref] == vehicle_ref }
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

      # Output the departure time if valid, nil if not.
      # A departure is considered valid if it is after the previous departure, but
      # not more than 20 minutes after.

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

  def self.all_trip_sequences(trip_view, destination_ref)
    # self.trip_sequence can return different vehicle trips depending on key_stop_ref.
    # Return all possible, useful trip sequences that can be gleaned from a given trip view.

    result = []
    unique_vehicle_trips = []
    matching_departures = trip_view[:destinations][destination_ref][:matching_departures]
    stop_refs = matching_departures.map { |d| d[:stop_ref] }

    stop_refs.each do |stop_ref|
      # make set from trip sequence, trying stop_ref as the key_stop_ref
      current_trip_sequence = trip_sequence(matching_departures, stop_ref)
      sequence_set = Set.new(current_trip_sequence)
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

    result.select { |trip_sequence| trip_sequence.count { |ts| ts[:departure_time].present? } >= min_length }
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

    # Shave off nil values from the end
    result = trip_sequence[:trip_sequence].reverse.drop_while { |d| d[:departure_time].blank? }.reverse

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

  def ordered_stop_refs(direction_ref = nil)
    return nil if self.stop_refs_response.nil?

    if self.updated_at < 21.days.ago
      logger.info "Refreshing stop_refs for #{self.line_ref}"
      self.update_stop_refs
    end

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

    if direction_ref.present?
      result[direction_ref][:stop_refs]
    else
      result
    end
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
