# frozen_string_literal: true

require 'concurrent'
require 'date'
require 'slop'

module Raspishika
  begin
    OPTIONS = Slop.parse do |opts|
      opts.string '--log-level', 'Log level, defaults to debug', default: 'debug'
      opts.string '-N', '--notify', 'Send a notification message to all users.'
      opts.on '-h', '--help', 'This help message' do
        puts opts
        exit
      end
    end
  rescue Slop::UnknownOption => e
    puts "Error: #{e.message}."
    puts 'Use --help for help.'
  end
end

require_relative 'main_bot'

if (message = Raspishika::OPTIONS[:notify])
  require_relative 'notification'

  Raspishika::User.logger = Logger.new $stderr
  Raspishika::User.load
  Raspishika.notify message
  exit
end

Raspishika::Bot.new.run
