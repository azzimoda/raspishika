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
          {command: 'general', description: 'Get general statistics'},
          {command: 'groups', description: 'Get groups statistics'},
          {command: 'departments', description: 'Get departments statistics'},
          {command: 'new_users', description: 'Get new users for last N=1 hours'},
          {command: 'commands', description: 'Get commands usage statistics for last 24 hours'},
          {command: 'configuration', description: 'Get configuration statistics'},
          {command: 'update_statistics_cache', description: 'Update statistics cache'},
          {command: 'help', description: 'No help'},
          {command: 'start', description: 'Start'},
        ]
      )
      begin
        bot.listen { handle_message it }
      rescue Telegram::Bot::Exceptions::ResponseError => e
        logger.error('DevBot') { "Telegram API error: #{e.detailed_message}" }
        logger.error('DevBot') { "Retrying..." }
        retry
      rescue => e
        logger.error('DevBot') { "Unhandled error in bot listen loop: #{e.detailed_message}" }
        logger.error('DevBot') { "Backtrace: #{e.backtrace.join("\n")}" }
        logger.error('DevBot') { "Retrying..." }
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
    when '/general' then send_general_statistics message
    when '/departments' then send_departments message
    when '/groups' then send_groups message
    when '/configuration' then send_configuration_statistics message
    when '/commands' then send_commands_statistics message
    when '/update_statistics_cache' then collect_statistics cache: false
    when '/new_users' then send_new_users message
    when %r(/new_users\s+(\d+)) then send_new_users message, days: Regexp.last_match(1).to_i
    else bot.api.send_message(chat_id: message.chat.id, text: "Huh?")
    end
  rescue => e
    bot.api.send_message(
      chat_id: @admin_chat_id, text: "Unlandled error in `#handle_message`: #{e.detailed_message}"
    )
    bot.api.send_message(chat_id: @admin_chat_id, text: "```\n#{e.backtrace.join("\n")}\n```", parse_mode: 'Markdown')
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
    text = groups.map { '`%15s (%2d users)`' % it }.join("\n")
    bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
  end

  def send_general_statistics message
    statistics = collect_statistics

    total_chats = statistics[:private_chats].size + statistics[:group_chats].size
    total_command_used = statistics[:command_usages].values.map(&:size).sum
    schedule_command_used = statistics[:command_usages].slice(:week, :tomorrow, :left)
      .values.map(&:size).sum
    top_groups = statistics[:groups].select { it }.transform_values(&:size)
      .sort_by(&:last).reverse.first(3).map { |name, count| "#{just_group name} (#{count})" }
    top_departments = statistics[:departments].select { it }.transform_values(&:size)
      .sort_by(&:last).reverse.first(3).map { |name, count| "#{name} (#{count})" }

    text = <<~MARKDOWN
      GENERAL

      Total chats: #{total_chats}
      Private chats: #{statistics[:private_chats].size}
      Group chats: #{statistics[:group_chats].size}

      Total groups: #{statistics[:groups].size}
      Top 3 groups by students:
      #{top_groups.join "\n"}
      (/groups)

      Total departments: #{statistics[:departments].size}
      Top 3 departments by groups:
      #{top_departments.join "\n"}
      (/departments)

      LAST 24 HOURS

      New users: #{statistics[:new_users].size}
      (/new_users)

      Total commands used: #{total_command_used}
      Schedule commands used: #{schedule_command_used}
      (/commands)
    MARKDOWN
    bot.api.send_message(chat_id: message.chat.id, text:)
  end

  def send_new_users(message, days: 1)
    users = if days == 0
      User.users.values
    else
      User.users.values.select do |user| 
        user.statistics[:start] && user.statistics[:start] >= Time.now - days * 24 * 60 * 60
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

    text = "No new users for the period." if text.strip.empty?
    bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
  end

  def send_configuration_statistics message
    statistics = collect_statistics

    daily_sending = statistics[:daily_sending_configuration].map do |time, users|
      groups = users.map(&:group_name).uniq.size
      "`%5s => %2s groups, %2s users`" % [time ? time : 'off', groups, users.size]
    end.join("\n")
    pair_sending = statistics[:pair_sending_configuration].map do |state, users|
      groups = users.map(&:group_name).uniq.size
      "`%5s => %2s groups, %2s users`" % [state ? 'on' : 'off', groups, users.size]
    end.join("\n")

    text = <<~MARKDOWN
      Pair sending configurations:

      #{pair_sending}

      Daily sending configurations:

      #{daily_sending}
    MARKDOWN
    bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
  end

  def send_commands_statistics message
    statistics = collect_statistics

    text = <<~MARKDOWN
      `
      /week                    => #{statistics[:command_usages][:week].size}
      /tomorrow                => #{statistics[:command_usages][:tomorrow].size}
      /left                    => #{statistics[:command_usages][:left].size}
      /set_group               => #{statistics[:command_usages][:config_group].size}
      /configure_sending       => #{statistics[:command_usages][:config_sending].size}
      /configure_daily_sending => #{statistics[:command_usages][:daily_sending].size}
      /pair_sending_on         => #{statistics[:command_usages][:pair_sending_on].size}
      /pair_sending_off        => #{statistics[:command_usages][:pair_sending_off].size}
      [other]                  => #{statistics[:command_usages][:other].size}
      `
    MARKDOWN
    bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
  end

  def collect_statistics cache: true
    logger.info "Collecting statistics..."
    start_time = Time.now

    statistics = {
      private_chats: [],
      group_chats: [], # 
      groups: {}, # group => chats
      departments: {}, # department => groups
      new_users: [],
      daily_sending_configuration: {}, # time => chats
      pair_sending_configuration: {}, # state(nil,false,true) => chats
      command_usages: {
        week: [],
        tomorrow: [],
        left: [],
        config_group: [],
        config_sending: [],
        daily_sending: [],
        pair_sending_on: [],
        pair_sending_off: [],
        other: []
      }
    }
    bot_name = bot.api.get_me.username.downcase
    User.users.values.each do |user|
      if user.id.to_i > 0
        statistics[:private_chats] << user
      else
        statistics[:group_chats] << user
      end

      statistics[:groups][user.group_name] ||= []
      statistics[:groups][user.group_name] << user

      statistics[:departments][user.department_name] ||= Set.new
      statistics[:departments][user.department_name] << user.group_name

      statistics[:daily_sending_configuration][user.daily_sending] ||= []
      statistics[:daily_sending_configuration][user.daily_sending] << user

      statistics[:pair_sending_configuration][user.pair_sending] ||= []
      statistics[:pair_sending_configuration][user.pair_sending] << user

      if user.statistics[:start].then { it && it >= Time.now - 24*60*60 }
        statistics[:new_users] << user
      end

      commands_statistics = Cache
        .fetch(:"command_usage_statistics_#{user.id}", expires_in: (cache ? 10*60 : 0), log: false) do
          user.statistics[:last_commands].group_by do |usage|
            case usage[:command].downcase.then do
              it.end_with?("@#{bot_name}") ? it.match(/^(.*)@#{bot_name}$/).match(1) : it
            end
            when '/week', LABELS[:week].downcase then :week
            when '/tomorrow', LABELS[:tomorrow].downcase then :tomorrow
            when '/left', LABELS[:left].downcase then :left
            when '/set_group', LABELS[:select_group].downcase then :config_group
            when '/configure_sending', LABELS[:configure_sending].downcase then :config_sending
            when '/configure_daily_sending', LABELS[:daily_sending].downcase then :daily_sending
            when '/pair_sending_on', LABELS[:pair_sending_on].downcase then :pair_sending_on
            when '/pair_sending_off', LABELS[:pair_sending_off].downcase then :pair_sending_off
            else :other
            end
          end
        end

      statistics[:command_usages].each { |k, v| v.push(*commands_statistics[k]) }
    end

    logger.debug "Statistics collection took #{Time.now - start_time} seconds"

    statistics
  end
end

def just_group group
  return '' if group.nil? || group.empty?

  if group =~ /^(\S+)-(\d+)-\((\d+)\)-(\d+)$/
    prefix, year, num, suffix = $1, $2, $3, $4
    "#{prefix.ljust(5)}-#{year}-(%2d)-#{suffix}" % num.to_i
  else group
  end
end
