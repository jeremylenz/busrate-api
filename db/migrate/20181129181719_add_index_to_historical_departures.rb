class AddIndexToHistoricalDepartures < ActiveRecord::Migration[5.2]
  def change
    add_index :historical_departures, [:stop_ref, :line_ref], name: "by_stop_line_ref"
    add_index(:historical_departures, :departure_time, name: "by_departure_time", order: {departure_time: :desc})
  end
end
