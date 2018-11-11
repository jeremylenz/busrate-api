class RemoveIntegerFromVehiclePosition < ActiveRecord::Migration[5.2]
  def change
    remove_column :vehicle_positions, :integer
  end
end
