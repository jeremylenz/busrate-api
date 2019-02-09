class BusLine < ApplicationRecord

  has_many :vehicle_positions
  validates_presence_of :line_ref
  validates_uniqueness_of :line_ref

  def ordered_stop_refs
    return nil if self.response.nil?

    response = JSON.parse(self.response)
    stop_groups_data = response['data']['entry']['stopGroupings'][0]['stopGroups']

    stop_groups_data.map do |stop_group|
      destination_name = stop_group['name']['name']
      stop_refs = stop_group['stopIds']
      {
        destination_name: destination_name,
        stop_refs: stop_refs,
      }
    end
  end

end
