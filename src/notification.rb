# frozen_string_literal: true

require 'telegram/bot'

require_relative 'main_bot'
require_relative 'user'

module Raspishika
  def self.notify(message, private_only: false)
    logger = User.logger
    logger.info "Sending notification to #{User.users.size} users..."
    count = 0
    skipped_count = 0
    blocked_count = 0
    Telegram::Bot::Client.run(Bot::TOKEN) do |bot|
      logger.info 'Bot initialized...'
      User.users.each_value do |user|
        if !private_only || bot.api.get_chat(chat_id: user.id).type == 'private'
          logger.debug "Sending notification to user ##{user.id}..."
          bot.api.send_message(chat_id: user.id, text: message)
          count += 1
        else
          skipped_count += 1
        end
      rescue Telegram::Bot::Exceptions::ResponseError => e
        case e.error_code
        when 403 # Forbidden: bot was blocked by the user / kicked from the group
          logger.warn "Bot was blocked in chat ##{user.id} @#{bot.api.get_chat(chat_id: user.id).username}"
          blocked_count += 1
        else
          logger.error "Error while sending notification to user ##{user.id}: #{e.error_message}"
        end
      rescue StandardError => e
        logger.error "Error while sending notification: #{e.detailed_message}"
        logger.error e.backtrace.join("\n\t")
        logger.info 'Trying to continue...'
      end
      logger.info "Successfully sent notification to #{count} chats" \
                  " (#{User.users.size - count - skipped_count} failed, #{blocked_count} of them blocked)"
    end
  end
end
