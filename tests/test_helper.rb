# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/spec'

OPTIONS = { 'log_level' => 'debug' }.freeze

require_relative '../src/main_bot'

def initialize_bot(**options)
  bot = Raspishika::Bot.new
  bot.stub
end

def initialize_parser
  parser = Raspishika::ScheduleParser.new logger: Logger.new($stdout)
  parser.initialize_browser_thread
  sleep 0.1 until parser.ready?
  parser
end

def teachers_set
  parser = initialize_parser
  teachers = parser.fetch_teachers(cache: false).to_a.sample(5)
  parser.stop_browser_thread
  teachers
end

def groups_set
  parser = initialize_parser
  groups = parser.fetch_all_groups(parser.fetch_departments).map do |dname, groups|
    { department: dname, group: groups.keys.sample }
  end
  parser.stop_browser_thread
  groups.select { it[:group] }
end
