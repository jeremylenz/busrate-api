class AddVehicleRefToHistoricalDeparture < ActiveRecord::Migration[5.2]
  def change
    add_column :historical_departures, :vehicle_ref, :string
  end
end
