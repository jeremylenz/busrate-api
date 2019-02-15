class AddInterpolatedToHistoricalDeparture < ActiveRecord::Migration[5.2]
  def change
    add_column :historical_departures, :interpolated, :boolean
  end
end
