class AddBusStopIdToVehiclePositions < ActiveRecord::Migration[5.2]
  def change
    add_column :vehicle_positions, :bus_stop_id, :bigint
  end
end
