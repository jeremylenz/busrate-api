class CreateBusLines < ActiveRecord::Migration[5.2]
  def change
    create_table :bus_lines do |t|
      t.string :line_ref
      t.json :response

      t.timestamps
    end
  end
end
