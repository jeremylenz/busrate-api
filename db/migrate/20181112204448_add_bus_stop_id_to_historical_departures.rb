class AddBusStopIdToHistoricalDepartures < ActiveRecord::Migration[5.2]
  def change
    add_column :historical_departures, :bus_stop_id, :bigint
  end
end
