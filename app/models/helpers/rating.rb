class Rating
  def initialize(departures, allowable_headway_in_minutes, current_headway = nil)
    @departures = departures
    @allowable_headway_in_minutes = allowable_headway_in_minutes
    @current_headway = current_headway

    crunch_numbers
    self.score
  end

  def score
    {
      average_headway: @average_headway,
      headways_count: @num_headways,
      standard_deviation: @standard_deviation,
      bunched_headways_count: @bunched_headways_count,
      percent_of_deps_bunched: @percent_of_deps_bunched,
      anti_bonus: @anti_bonus,
      allowable_total: @allowable_total,
      actual_total: @actual_total,
      raw_score: @raw_score,
      busrate_score: @busrate_score,
      current_headway: @current_headway,
      score_incorporates_current_headway: @current_headway.present?,
    }
  end

  private

    def crunch_numbers
      start_time = Time.current

      headways = @departures.pluck(:headway).compact
      @num_headways = headways.count
      if headways.blank? || headways.count < 2
        @busrate_score = nil
        @num_headways = nil
        return
      end
      headways_in_minutes = headways.map { |headway| (headway / 60).round }

      if @current_headway
        headways.unshift(@current_headway)
        headways_in_minutes.unshift(@current_headway / 60)
      end


      # any arrival within 2 minutes of the previous vehicle counts as bunching
      unbunched_headways = headways.select { |headway| headway >= 120 } # Don't allow bus bunching to 'improve' average headway

      # Use the descriptive_statistics gem to get cool stats
      @average_headway = unbunched_headways.mean.round(2)
      @standard_deviation = headways.standard_deviation.round(2)

      allowable_headway = @allowable_headway_in_minutes * 60 # convert to seconds
      @allowable_total = (@num_headways * allowable_headway).round
      @actual_total = headways.sum

      @anti_bonus = (@standard_deviation - @average_headway) * @num_headways
      # If @standard_deviation > @average_headway, allowable_total will go DOWN.
      if @anti_bonus < 0
        @anti_bonus = 0
      end

      @bunched_headways_count = headways.count { |headway| headway < 120 } # any arrival within 2 minutes of the previous vehicle counts as bunching
      @bunched_headways_count *= 2 # count both departures in the bunch as bunched
      @percent_of_deps_bunched = ((@bunched_headways_count.to_f / headways.count.to_f) * 100.0).round(1)
      @anti_bonus += (allowable_headway * @bunched_headways_count)

      @allowable_total -= @anti_bonus

      @busrate_score = (@allowable_total / @actual_total * 100).round
      @raw_score = @busrate_score
      if @busrate_score > 100
        @busrate_score = 100
      end
      if @busrate_score < 0
        @busrate_score = 0
      end

      completion_time = (Time.current - start_time).round(2)
      logger.info "Done calculating BusRate score after #{completion_time} seconds" unless completion_time < 3
    end
end

# def self.rating(departures, allowable_headway_in_minutes, current_headway = nil)
#   start_time = Time.current
#
#   headways = departures.pluck(:headway).compact
#   num_headways = headways.count
#   if headways.blank? || headways.count < 2
#     return {
#       busrate_score: nil,
#       headways_count: num_headways,
#     }
#   end
#   headways_in_minutes = headways.map { |headway| (headway / 60).round }
#
#   if current_headway
#     headways.unshift(current_headway)
#     headways_in_minutes.unshift(current_headway / 60)
#   end
#
#
#   # any arrival within 2 minutes of the previous vehicle counts as bunching
#   unbunched_headways = headways.select { |headway| headway >= 120 } # Don't allow bus bunching to 'improve' average headway
#
#   # Use the descriptive_statistics gem to get cool stats
#   average_headway = unbunched_headways.mean.round(2)
#   standard_deviation = headways.standard_deviation.round(2)
#
#   allowable_headway = allowable_headway_in_minutes * 60 # convert to seconds
#   allowable_total = (num_headways * allowable_headway).round
#   actual_total = headways.sum
#
#   anti_bonus = (standard_deviation - average_headway) * num_headways
#   # If standard_deviation > average_headway, allowable_total will go DOWN.
#   if anti_bonus < 0
#     anti_bonus = 0
#   end
#
#   bunched_headways_count = headways.count { |headway| headway < 120 } # any arrival within 2 minutes of the previous vehicle counts as bunching
#   bunched_headways_count *= 2 # count both departures in the bunch as bunched
#   percent_of_deps_bunched = ((bunched_headways_count.to_f / headways.count.to_f) * 100.0).round(1)
#   anti_bonus += (allowable_headway * bunched_headways_count)
#
#   allowable_total -= anti_bonus
#
#   busrate_score = (allowable_total / actual_total * 100).round
#   raw_score = busrate_score
#   if busrate_score > 100
#     busrate_score = 100
#   end
#   if busrate_score < 0
#     busrate_score = 0
#   end
#
#   completion_time = (Time.current - start_time).round(2)
#   logger.info "Done calculating BusRate score after #{completion_time} seconds" unless completion_time < 3
#
#   {
#     # headways_in_minutes: headways_in_minutes,
#     average_headway: average_headway,
#     headways_count: num_headways,
#     standard_deviation: standard_deviation,
#     bunched_headways_count: bunched_headways_count,
#     percent_of_deps_bunched: percent_of_deps_bunched,
#     anti_bonus: anti_bonus,
#     allowable_total: allowable_total,
#     actual_total: actual_total,
#     raw_score: raw_score,
#     busrate_score: busrate_score,
#     current_headway: current_headway,
#     score_incorporates_current_headway: current_headway.present?,
#   }
# end
