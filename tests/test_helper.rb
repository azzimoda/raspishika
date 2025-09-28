# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/spec'

OPTIONS = { 'log_level' => 'debug' }.freeze

require_relative '../src/main_bot'

def initialize_bot(**options)
  Raspishika::Bot.new
end

def initialize_parser
  parser = Raspishika::ScheduleParser.new
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
  groups = parser.fetch_all_groups.map { |dname, groups| { department: dname, group: groups.keys.sample } }
  parser.stop_browser_thread
  groups.select { it[:group] }
end
