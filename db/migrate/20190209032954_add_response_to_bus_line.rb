class AddResponseToBusLine < ActiveRecord::Migration[5.2]
  def change
    add_column :bus_lines, :response, :json
  end
end
