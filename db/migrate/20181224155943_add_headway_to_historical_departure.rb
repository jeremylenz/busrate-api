class AddHeadwayToHistoricalDeparture < ActiveRecord::Migration[5.2]
  def change
    add_column :historical_departures, :headway, :bigint
    add_column :historical_departures, :previous_departure_id, :bigint
  end
end
