class MtaBusLineList < ApplicationRecord

  after_create :refresh_bus_lines

  def self.latest
    order(created_at: :desc).first
  end

  private

    def refresh_bus_lines
      logger.info "refresh_bus_lines"
      bus_lines = JSON.parse(self.response).compact
      bus_lines.each do |bus_line_data|
        existing_bus_line = BusLine.where(line_ref: bus_line_data['id']).first
        if existing_bus_line.present? && JSON.parse(existing_bus_line.response) != bus_line_data
          existing_bus_line.update(
            response: JSON.generate(bus_line_data)
          )
        end
        if existing_bus_line.blank?
          BusLine.create(
            line_ref: bus_line_data['id'],
            response: JSON.generate(bus_line_data)
          )
        end
      end

    end

end
