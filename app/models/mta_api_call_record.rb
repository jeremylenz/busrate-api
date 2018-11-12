class MtaApiCallRecord < ApplicationRecord

  def self.most_recent
    self.order(created_at: :desc).first
  end
  
end
