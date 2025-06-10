require 'telegram/bot'

require_relative 'user'

module Raspishika
  def notify message
    User.logger.info "Sending notification to #{User.users.size} users..."
    count = 0
    Telegram::Bot::Client.run(ENV['TELEGRAM_BOT_TOKEN']) do |bot|
      User.logger.info "Bot initialized..."
      User.users.each_value do |user|
        User.logger.debug "Sending notification to user #{user.id}"
        bot.api.send_message(chat_id: user.id, text: message)
        count += 1
      rescue => e
        User.logger.error "Error while sending notification: #{e.detailed_message}"
        User.logger.debug e.backtrace.join("\n")
        User.logger.error "Trying to continue..."
      end
      User.logger.info "Successfully sent contification to #{count} users"
    end
  end
end
