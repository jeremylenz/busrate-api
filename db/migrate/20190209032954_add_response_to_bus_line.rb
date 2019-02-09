class AddResponseToBusLine < ActiveRecord::Migration[5.2]
  def change
    add_column :bus_lines, :stop_refs_response, :json
  end
end
