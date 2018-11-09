class CreateHistoricalDepartures < ActiveRecord::Migration[5.2]
  def change
    create_table :historical_departures do |t|
      t.string :stop_ref
      t.string :line_ref
      t.datetime :departure_time

      t.timestamps
    end
  end
end
