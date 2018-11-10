class MtaBusLineList < ApplicationRecord

  def self.latest
    order(created_at: :desc).first
  end

end
