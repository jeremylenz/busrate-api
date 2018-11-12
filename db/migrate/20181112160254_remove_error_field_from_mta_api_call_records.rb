class RemoveErrorFieldFromMtaApiCallRecords < ActiveRecord::Migration[5.2]
  def change
    remove_column :mta_api_call_records, :timestamps
  end
end
