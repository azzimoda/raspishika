require 'concurrent'
require 'date'
require 'slop'

module Raspishika
  ROOT_DIR = File.expand_path('..', __dir__).freeze
  MAX_RETRIES = 5

  OPTIONS = Slop.parse do |opts|
    opts.string '-t', '--token', 'Main bot token'
    opts.string '-T', '--dev-token', 'Dev bot token'
    opts.on '-h', '--help', 'This help message' do
      puts opts
      exit
    end
    opts.on '--notify', 'Send a notification message to all users.' do |message|
      require_relative 'notification'

      User.logger = Logger.new $stderr
      User.restore
      notify message
      exit
    end
  end
end

require_relative 'main_bot'

Raspishika::Bot.new.run
