class CreateVehiclePositions < ActiveRecord::Migration[5.2]
  def change
    create_table :vehicle_positions do |t|
      t.belongs_to :vehicle
      t.belongs_to :bus_line
      t.string :vehicle_ref
      t.string :line_ref
      t.string :arrival_text
      t.string :feet_from_stop
      t.string :integer
      t.string :stop_ref
      t.datetime :timestamp

      t.timestamps
    end
  end
end
