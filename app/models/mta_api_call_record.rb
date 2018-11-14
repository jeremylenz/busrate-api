class MtaApiCallRecord < ApplicationRecord

  def self.most_recent
    MtaApiCallRecord.transaction do
      self.lock.order(created_at: :desc).limit(1).reload.first
    end
  end

end
