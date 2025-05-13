require './src/user'
require './src/cache'

module DebugCommands
  def self.user_info(bot:, user:, message:)
    bot.logger.debug "User info: #{user.inspect}"
    bot.bot.api.send_message(
      chat_id: message.chat.id,
      text: "[DEBUG] User info: #{user.inspect}"
    )
  end

  def self.fetch_schedule(bot:, sid: 28703, gr: 427)
    bot.logger.debug "Fetching schedule for sid=#{sid}, gr=#{gr}"
    schedule = Schedule.from_raw parser.fetch_schedule({sid: sid, gr: gr})
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
end
