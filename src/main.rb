require 'concurrent'
require 'date'
require 'slop'

module Raspishika
  ROOT_DIR = File.expand_path('..', __dir__).freeze
  MAX_RETRIES = 5

  begin
    OPTIONS = Slop.parse do |opts|
      opts.string '-t', '--token', 'Main bot token'
      opts.string '-T', '--dev-token', 'Dev bot token'
      opts.string '--log-level', 'Log level, defaults to debug', default: 'debug'
      opts.string '-N', '--notify', 'Send a notification message to all users.'
      opts.bool '--daily', 'Enable daily sending, defaults to true', default: true
      opts.bool '-D', '--dev-bot', 'Enable dev bot, defaults to true', default: true
      opts.bool '-C', '--debug-commands', 'Enable debug commands', default: false
      opts.on '-h', '--help', 'This help message' do
        puts opts
        exit
      end
    end
  rescue Slop::UnknownOption => e
    puts "Error: #{e.message}."
    puts "Use --help for help."
  end
end

require_relative 'main_bot'

if (message = Raspishika::OPTIONS[:notify])
  require_relative 'notification'

  Raspishika::User.logger = Logger.new $stderr
  Raspishika::User.restore
  Raspishika.notify message
  exit
end

Raspishika::Bot.new.run
