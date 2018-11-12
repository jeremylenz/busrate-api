class CreateMtaApiCallRecords < ActiveRecord::Migration[5.2]
  def change
    create_table :mta_api_call_records do |t|
      t.string :timestamps

      t.timestamps
    end
  end
end
