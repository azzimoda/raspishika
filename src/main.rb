# frozen_string_literal: true

require 'date'
require 'slop'

module Raspishika
  begin
    OPTIONS = Slop.parse do |opts|
      opts.string '--log-level', 'Log level, defaults to debug', default: 'debug'
      opts.string '-N', '--notify', 'Send a notification message to all chats.'
      opts.string '-P', '--notify-private', 'Send a notification message to all private chats.'

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

  Raspishika.notify message
  exit
end

if (message = Raspishika::OPTIONS[:notify_private])
  require_relative 'notification'

  Raspishika.notify message, private_only: true
  exit
end

Raspishika::Bot.new.run
