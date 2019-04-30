require 'rails_helper'

RSpec.describe HistoricalDeparture, type: :model do
  let(:bus_stop) { BusStop.new }
  let(:subject) {
    HistoricalDeparture.new(
      headway: nil,
      bus_stop: bus_stop,
    )
  }
  describe 'validations:' do
    it 'is valid with valid properties' do
      expect(subject).to be_valid
    end

    it 'is not valid with an invalid headway' do
      subject.headway = 0
      expect(subject).not_to be_valid
    end
  end
end
