class BusLine < ApplicationRecord

  validates_uniqueness_of :line_ref

end
