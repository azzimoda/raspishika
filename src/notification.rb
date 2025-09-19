# frozen_string_literal: true

require 'telegram/bot'
require 'concurrent'

require_relative 'main_bot'
require_relative 'database'

module Raspishika
  def self.notify(message, private_only: false)
    chats = Chat.all

    logger.info "Sending notification to #{chats.count} chats..."
    Telegram::Bot::Client.run(Bot::TOKEN) do |bot|
      thread_pool = Concurrent::FixedThreadPool.new 20
      logger.info 'Bot initialized'

      futures = chats.map do |c|
        next :skipped if private_only && c.tg_id.to_i.positive?

        Concurrent::Future.execute(executor: thread_pool) { send_notification bot, c, message }
      end
      futures.each(&:wait)
      thread_pool.shutdown

      results = futures.map(&:value)
      logger.info "Successfully sent notification to #{results.count(:ok)} chats" \
                  " (#{chats.count - results.count(:ok) - results.count(:skipped)} failed," \
                  " #{results.count(:blocked)} of them blocked)"
    end
  end

  private

  def send_notification(bot, chat, message)
    logger.debug "Sending notification to chat ##{chat.tg_id}..."
    bot.api.send_message(chat_id: chat.tg_id, text: message)
    :ok
  rescue Telegram::Bot::Exceptions::ResponseError => e
    case e.error_code
    when 403 # Forbidden: bot was blocked by the user / kicked from the group
      logger.warn "Bot was blocked in chat ##{chat.tg_id} @#{bot.api.get_chat(chat_id: chat.tg_id).username}"
      :blocked
    else
      logger.error "Error while sending notification to chat ##{chat.tg_id}: #{e.error_message}"
      :failed
    end
  rescue StandardError => e
    logger.error "Error while sending notification: #{e.detailed_message}"
    logger.error e.backtrace.join("\n\t")
    logger.info 'Trying to continue...'
    :failed
  end
end
