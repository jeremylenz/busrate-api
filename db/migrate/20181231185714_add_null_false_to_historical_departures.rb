class AddNullFalseToHistoricalDepartures < ActiveRecord::Migration[5.2]
  def change
    change_column_null :historical_departures, :stop_ref, false
    change_column_null :historical_departures, :line_ref, false
  end
end
