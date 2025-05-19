require 'telegram/bot'
require_relative 'user'

def notify message
  User.logger.info "Sending notification to #{User.users.size} users..."
  Telegram::Bot::Client.run(ENV['TELEGRAM_BOT_TOKEN']) do |bot|
    User.logger.info "Bot initialized..."
    User.users.each_value do |user|
      bot.api.send_message(chat_id: user.id, text: message)
    end
  end
end
