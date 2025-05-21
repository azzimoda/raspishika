require 'json'
require 'telegram/bot'

require_relative 'user'

class RaspishikaDevBot
  ADMIN_CHAT_ID_FILE = File.expand_path('../data/admin_chat_id', __dir__).freeze

  def initialize logger: nil
    @logger = logger || Logger.new($stderr, level: Logger::ERROR)
    @token = ENV['DEV_BOT_TOKEN']
    @admin_chat_id = File.read(ADMIN_CHAT_ID_FILE).chomp.to_i rescue nil
    @run = ENV['DEV_BOT'] ? ENV['DEV_BOT'] == 'true' : true
  end
  attr_accessor :logger, :bot

  def run
    return unless @run
    unless @token
      logger.warn('DevBot') { "Token for statistics bot is not set! It won't run." }
      return
    end

    logger.info('DevBot') { "Starting statistics bot..." }
    Telegram::Bot::Client.run(@token) do |bot|
      logger.info('DevBot') { "Bot is running." }
      @bot = bot
      bot.api.set_my_commands(
        commands: [
          {command: 'departments', description: 'Get departments statistics'},
          {command: 'groups', description: 'Get groups statistics'},
          {command: 'chats', description: 'Get chats statistics'},
          {command: 'new_users', description: 'Get new users of a period (days)'},
          {command: 'log', description: 'Get last log'},
          {command: 'help', description: 'No help'},
          {command: 'start', description: 'Start'},
        ]
      )
      begin
        bot.listen { handle_message it }
      rescue Telegram::Bot::Exceptions::ResponseError => e
        logger.error('DevBot') { "Telegram API error: #{e.detailed_message}\n\tRetrying..." }
        retry
      end
    end
  rescue Interrupt
    puts
    logger.warn('DevBot') { "Keyboard interruption" }
  ensure
    File.write(ADMIN_CHAT_ID_FILE, @admin_chat_id.to_s) if @admin_chat_id
  end

  def report text, photo: nil, backtrace: nil, log: nil
    return unless @token && @admin_chat_id && @run

    logger.info('DevBot') { "Sending report #{text.inspect}..." }
    bot.api.send_photo(chat_id: @admin_chat_id, photo:) if photo
    if log
      bot.api.send_message(
        chat_id: @admin_chat_id,
        text: "LOGS:\n```\n#{last_log lines: log}\n```",
        parse_mode: 'Markdown'
      )
    end
    if backtrace
      bot.api.send_message(
        chat_id: @admin_chat_id,
        text: "BACKTRACE:\n```\n#{backtrace}\n```",
        parse_mode: 'Markdown'
      )
    end
    bot.api.send_message(chat_id: @admin_chat_id, text:)
  end

  private

  def handle_message message
    case message.text.downcase
    when '/start' then @admin_chat_id = message.chat.id
    when ->(*) { @admin_chat_id.nil? } then return
    when %r(/log\s+(\d+)) then send_log message, lines: Regexp.last_match(1).to_i
    when '/log' then send_log message
    when '/departments' then send_departments message
    when '/groups' then send_groups message
    when '/chats' then send_chats message
    when '/new_users' then send_new_users message
    when %r(/new_users\s+(\d+)) then send_new_users message, days: Regexp.last_match(1).to_i
    else bot.api.send_message(chat_id: message.chat.id, text: "Huh?")
    end
  rescue => e
    bot.api.send_message(
      chat_id: @admin_chat_id, text: "Unlandled error in `#handle_message`: #{e.detailed_message}"
    )
  end

  def send_log message, lines: 20
    log = last_log(lines:)
    if log && !log.empty?
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "```\n#{log}\n```",
        parse_mode: 'Markdown'
      )
    else
      bot.api.send_message(chat_id: message.chat.id, text: "No log.")
    end
  end

  def last_log lines: 20
    File.exist?(logger.log_file) ? `tail -n #{lines} #{logger.log_file.shellescape}` : ''
  rescue => e
    "Failed to get last log: #{e.detailed_message}".tap { logger.error it; report it }
    ''
  end

  def send_departments message
    departments = {}
    User.users.each_value do |user|
      departments[user.department_name] ||= {groups: Set.new, users: 0}
      departments[user.department_name][:groups].add user.group
      departments[user.department_name][:users] += 1
    end
    departments.each_value { it[:groups] = it[:groups].size }

    text = departments.sort { |a, b| a[1][:groups] <=> b[1][:groups] }
      .map { |k, v| "#{k} (#{v[:groups]} groups, #{v[:users]} users)" }
      .join("\n")
    bot.api.send_message(chat_id: message.chat.id, text:)
  end

  def send_groups message
    groups = {}
    User.users.each_value do |user|
      groups[user.group_name] ||= 0
      groups[user.group_name] += 1
    end

    text = groups.sort { |a, b| a[1] <=> b[1] }
      .map { |k, v| "#{k} (#{v} users)" }
      .join("\n")
    bot.api.send_message(chat_id: message.chat.id, text:)
  end

  def send_chats message
    private_chats = 0
    group_chats = 0
    User.users.each_value { it.id.to_i > 0 ? private_chats += 1 : group_chats += 1 }

    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Private chats: #{private_chats}; Group chats: #{group_chats}."
    )
  end

  def send_new_users message, days: 1
    users = User.users.values.select do |user| 
      user.statistics[:start] && user.statistics[:start] >= Time.now - days * 24 * 60 * 60
    end
    text = users.map do |user|
      "#{user.id} #{user.statistics[:start].strftime('%F %T')} #{user.department_name} #{user.group_name}"
    end.join("\n")

    if text.strip.empty?
      bot.api.send_message(chat_id: message.chat.id, text: "No new users for the period.")
    else
      bot.api.send_message(chat_id: message.chat.id, text:)
    end
  end
end
