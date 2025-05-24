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
          {command: 'log', description: 'Get last log'},
          {command: 'departments', description: 'Get departments statistics'},
          {command: 'groups', description: 'Get groups statistics'},
          {command: 'chats', description: 'Get chats statistics'},
          {command: 'new_users', description: 'Get new users of a period (days)'},
          {command: 'daily_sending_statistics', description: 'Get daily sending statistics'},
          {command: 'pair_sending_statistics', description: 'Get pair sending statistics'},
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
    when '/daily_sending_statistics' then send_daily_sending_statistics message
    when '/pair_sending_statistics' then send_pair_sending_statistics message
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
    departments = User.users.values.group_by(&:department_name)
      .transform_keys { it.to_s.ljust 14 }
      .transform_values { it.group_by(&:group_name).then { [it.size, it.values.sum(&:size)] } }
      .sort_by(&:last)
      .reverse

    text = departments
      .map { |k, v| '`%s (%2d groups, %2d users)`' % ([k] + v) }
      .join("\n")
    bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
  end

  def send_groups message
    groups = User.users.values.group_by(&:group_name)
      .transform_keys { just_group it }
      .transform_values(&:size)
      .sort_by(&:last)
      .reverse
    text = groups.map { '`%14s (%2d users)`' % it }.join("\n")
    bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
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

  def send_new_users(message, days: 1)
    users = if days == 0
      User.users.values
    else
      User.users.values.select do |user| 
        user&.statistics[:start] && user.statistics[:start] >= Time.now - days * 24 * 60 * 60
      end
    end

    text = users.map do |user|
      "`%19s %16s\n%14s %s`" % [
        user.statistics[:start]&.strftime('%F %T'),
        user.id,
        user.department_name,
        just_group(user.group_name)
      ]
    end.join("\n\n")

    if text.strip.empty?
      bot.api.send_message(chat_id: message.chat.id, text: "No new users for the period.")
    else
      bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
    end
  end

  def send_daily_sending_statistics message
    times = User.users.values.group_by(&:daily_sending)
      .transform_keys(&:to_s)
      .transform_values { it.group_by(&:group_name).then { [it.size, it.values.sum(&:size)] } }
      .sort_by(&:first)
    text = times.map { |time, (groups, users)|
      '`%5s (%2d groups, %2d users)`' % [time, groups, users]
    }.join("\n")
    bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
  end

  def send_pair_sending_statistics message
    states = User.users.values.group_by(&:pair_sending)
      .transform_keys { it ? 'on' : 'off' }
      .transform_values { it.group_by(&:group_name).then { [it.size, it.values.sum(&:size)] } }
    text = states.map do |state, (groups, users)|
      "`%3s (%2d groups, %2d users)`" % [state, groups, users]
    end.join("\n")
    bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
  end
end

def just_group group
  return '' if group.nil? || group.empty?

  if group =~ /^(\S+)-(\d+)-\((\d+)\)-(\d+)$/
    prefix, year, num, suffix = $1, $2, $3, $4
    "#{prefix.ljust(4)}-#{year}-(%2d)-#{suffix}" % num.to_i
  else group
  end
end  
