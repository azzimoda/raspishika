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
          {command: 'general_statistics', description: 'Get general statistics'},
          {command: 'groups', description: 'Get groups statistics'},
          {command: 'departments', description: 'Get departments statistics'},
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
    when '/general_statistics' then send_general_statistics message
    when '/departments' then send_departments message
    when '/groups' then send_groups message
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
    text = groups.map { '`%14s (%2d users)`' % it }.join("\n")
    bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
  end

  def send_general_statistics message
    statistics = collect_statistics

    total_chats = statistics[:private_chats].size + statistics[:group_chats].size
    total_command_used = statistics[:command_usages].values.map(&:size).sum
    schedule_command_used = statistics[:command_usages].slice(:week, :tomorrow, :left)
      .values.map(&:size).sum
    top_groups = statistics[:groups].transform_values(&:size).sort_by(&:last)
      .reverse.first(3).map { |name, count| "#{name} (#{count})" }
    top_departments = statistics[:departments].transform_values(&:size).sort_by(&:last)
      .reverse.first(3).map { |name, count| "#{name} (#{count})" }

    bot.api.send_message(
      chat_id: message.chat.id,
      text: <<~MARKDOWN
        Total chats: #{total_chats}
        Private chats: #{statistics[:private_chats].size}
        Group chats: #{statistics[:group_chats].size}

        Total groups: #{statistics[:groups].size}
        Top group: #{top_groups.join ', '}
        (/groups)

        Total departments: #{statistics[:departments].size}
        Top department by group: #{top_departments.join ', '}
        (/departments)

        LAST 24 HOURS

        New users: #{statistics[:new_users].size} (/new_users)
        Schedule commands used: #{schedule_command_used}/#{total_command_used}
      MARKDOWN
    )
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

  def collect_statistics
    logger.info "Collecting statistics..."
    start_time = Time.now

    statistics = {
      private_chats: [],
      group_chats: [],
      groups: {},
      departments: {},
      new_users: [],
      daily_sending_configuration: {},
      pair_sending_configuration: {},
      command_usages: {week: [], tomorrow: [], left: [], config_group: [], config_sending: []}
    }
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

      commands_statistics = Cache.fetch(:"command_usage_statistics_#{user.id}", expires_in: 10*60) do
        command_statistcs = {week: [], tomorrow: [], left: [], config_group: [], config_sending: []}
        [command_statistcs, user.statistics[:last_commands]].tap do |stats, usages|
          stats[:week] = count_commands usages, ['/week', LABELS[:week]]
          stats[:tomorrow] = count_commands usages, ['/tomorrow', LABELS[:tomorrow]]
          stats[:left] = count_commands usages, ['/left', LABELS[:left]]
          stats[:config_group] = count_commands usages, ['/set_group', LABELS[:select_group]]
          stats[:config_sending] =
            count_commands usages, ['/configure_sending', LABELS[:configure_sending]]
        end

        command_statistcs
      end

      statistics[:command_usages].each { |k, v| v.push(*commands_statistics[k]) }
    end

    logger.debug "Statistics collection took #{Time.now - start_time} seconds"

    statistics
  end

  def count_commands commands, pattern
    commands.count do |e|
      text = e[:command].downcase.then do
        if it.end_with?("@#{bot.api.get_me.username.downcase}")
          it.match(/^(.*)@#{bot.api.get_me.username.downcase}$/).match(1)
        else
          it
        end
      end
      if pattern.is_a? Regexp
        text =~ pattern
      else
        pattern.any? { it.downcase == text }
      end && e[:timestamp] >= Time.now - 24*60*60
    end
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
