# frozen_string_literal: true

require_relative 'test_helper'

describe Raspishika::ScheduleParser do
  let(:parser) { initialize_parser }

  groups_set.each do |group_info|
    it "should handle a schedule request for #{group_info.inspect}" do
      schedule = parser.fetch_schedule group_info, net_http: true
      _(schedule.nil?).must_equal false
    end
  end
end
