class AddTripIdentifiersIndicesToHistoricalDepartures < ActiveRecord::Migration[5.2]
  def change
    add_index(:historical_departures, :block_ref)
    add_index(:historical_departures, :dated_vehicle_journey_ref)
  end
end
