class AddTripIdentifiersToHistoricalDeparture < ActiveRecord::Migration[5.2]
  def change
    add_column :historical_departures, :block_ref, :string
    add_column :historical_departures, :dated_vehicle_journey_ref, :string
  end
end
