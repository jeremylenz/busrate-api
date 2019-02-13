class AddTripIdentifiersToVehiclePosition < ActiveRecord::Migration[5.2]
  def change
    add_column :vehicle_positions, :dated_vehicle_journey_ref, :string
    add_column :vehicle_positions, :block_ref, :string
  end
end
