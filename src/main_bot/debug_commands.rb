# frozen_string_literal: true

require_relative '../user'
require_relative '../cache'

module Raspishika
  module DebugCommands
    def self.user_info(bot:, user:, message:)
      logger.debug "User info: #{user.inspect}"
      bot.bot.api.send_message(
        chat_id: message.chat.id,
        text: "[DEBUG] User info: #{user.inspect}"
      )
    end

    def self.fetch_schedule(bot:, sid: 28703, gr: 427)
      logger.debug "Fetching schedule for sid=#{sid}, gr=#{gr}"
      schedule = Schedule.from_raw parser.fetch_schedule({ sid: sid, gr: gr})
      puts schedule.format
    end

    def self.set_user_info(user:, **)
      user.department = '28703'
      user.group = '427'
    end

    def self.delete_user(user:, **)
      User.delete user
    end

    def self.clear_cache(**)
      Cache.clear
    end

    def self.delete_department_name(user:, **)
      user.department_name = nil
    end

    def self.raise_error(**)
      raise "Test unhandled error"
    end

    def self.delete_start_timestamp(user:, **)
      user.statistics[:start] = nil
    end

    def self.send_pair_notification(user:, bot:, **)
      bot.send_pair_notification(Time.now, user: user)
    end
  end
end
