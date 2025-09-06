# frozen_string_literal: true

require 'telegram/bot'
require 'concurrent'

require_relative 'main_bot'
require_relative 'user'

module Raspishika
  def self.notify(message, private_only: false)
    logger = User.logger
    logger.info "Sending notification to #{User.users.size} users..."
    Telegram::Bot::Client.run(Bot::TOKEN) do |bot|
      thread_pool = Concurrent::FixedThreadPool.new 20
      logger.info 'Bot initialized...'
      futures = User.users.each_value.map do |user|
        Concurrent::Future.execute(executor: thread_pool) do
          if !private_only || bot.api.get_chat(chat_id: user.id).type == 'private'
            logger.debug "Sending notification to user ##{user.id}..."
            bot.api.send_message(chat_id: user.id, text: message)
            :ok
          else
            :skipped
          end
        rescue Telegram::Bot::Exceptions::ResponseError => e
          case e.error_code
          when 403 # Forbidden: bot was blocked by the user / kicked from the group
            logger.warn "Bot was blocked in chat ##{user.id} @#{bot.api.get_chat(chat_id: user.id).username}"
            :blocked
          else
            logger.error "Error while sending notification to user ##{user.id}: #{e.error_message}"
            :failed
          end
        rescue StandardError => e
          logger.error "Error while sending notification: #{e.detailed_message}"
          logger.error e.backtrace.join("\n\t")
          logger.info 'Trying to continue...'
          :failed
        end
      end
      futures.each(&:wait)
      thread_pool.shutdown

      results = futures.map(&:value)

      logger.info "Successfully sent notification to #{results.count(:ok)} chats" \
                  " (#{User.users.size - results.count(:ok) - results.count(:skipped)} failed," \
                  " #{results.count(:blocked)} of them blocked)"
    end
  end
end
