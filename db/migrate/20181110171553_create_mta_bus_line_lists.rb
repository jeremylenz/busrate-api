class CreateMtaBusLineLists < ActiveRecord::Migration[5.2]
  def change
    create_table :mta_bus_line_lists do |t|
      t.json :response

      t.timestamps
    end
  end
end
