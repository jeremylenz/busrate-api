class CreateBusStops < ActiveRecord::Migration[5.2]
  def change
    create_table :bus_stops do |t|

      t.string :stop_ref
      t.timestamps
      
    end
  end
end
