class AddDirectionRefToVehiclePosition < ActiveRecord::Migration[5.2]
  def change
    add_column :vehicle_positions, :direction_ref, :integer
  end
end
