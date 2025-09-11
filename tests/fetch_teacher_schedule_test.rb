# frozen_string_literal: true

require_relative 'test_helper'

describe Raspishika::ScheduleParser do
  let(:parser) { initialize_parser }

  teachers_set.each do |name, id|
    it "should fetch schedule for #{name} (#{id})" do
      schedule = parser.fetch_teacher_schedule id, name
      _(schedule.is_a?(Array)).must_equal true
    end
  end
end
