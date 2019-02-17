class AddDirectionRefToHistoricalDeparture < ActiveRecord::Migration[5.2]
  def change
    add_column :historical_departures, :direction_ref, :integer
  end
end
