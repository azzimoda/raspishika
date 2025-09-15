# frozen_string_literal: true

require_relative 'test_helper'

describe Raspishika::ScheduleParser do
  let(:logger) { Raspishika.logger!(file: false) }

  before do
    @parser = initialize_parser
  end
  after do
    @parser.stop_browser_thread
  end

  it 'should fetch teachers names and ids' do
    teachers = @parser.fetch_teachers cache: false
    _(teachers).wont_be :empty?
    _(teachers.each_value).must_be :all?
  end
end
