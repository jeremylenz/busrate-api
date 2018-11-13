class MtaApiCallRecord < ApplicationRecord

  def self.most_recent
    self.limit(10).each(&:reload)
    self.order(created_at: :desc).limit(1).reload.first
  end

end
