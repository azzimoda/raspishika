require 'json'
require 'rufus-scheduler'
require 'telegram/bot'

require_relative 'user'

module Raspishika
  class DevBot
    TOKEN_FILE = File.expand_path('config/token_dev', ROOT_DIR)
    ADMIN_CHAT_ID_FILE = File.expand_path('../data/admin_chat_id', __dir__).freeze
    MY_COMMANDS = [
      {command: 'log', description: 'Get last log'},
      {command: 'general', description: 'Get general statistics'},
      {command: 'groups', description: 'Get groups statistics'},
      {command: 'departments', description: 'Get departments statistics'},
      {command: 'new_chats', description: 'Get new users for last N=1 hours'},
      {command: 'commands', description: 'Get commands usage statistics for last 24 hours'},
      {command: 'configuration', description: 'Get configuration statistics'},
      {command: 'update_statistics_cache', description: 'Update statistics cache'},
      {command: 'help', description: 'No help'},
      {command: 'start', description: 'Start'},
    ]

    def initialize main_bot:, logger: nil
      @main_bot = main_bot

      @logger = logger || ::Logger.new($stderr, level: ::Logger::ERROR)
      @token = if OPTIONS[:dev_token]
        OPTIONS[:dev_token]
      else
        begin
          File.read('config/token_dev').chomp
        rescue Errno::ENOENT
          logger.error "No `config/token_dev` file found."
          logger.warn "The dev bot won't run."
        end
      end
      @admin_chat_id = File.read(ADMIN_CHAT_ID_FILE).chomp.to_i rescue nil
      @run = OPTIONS[:dev_bot]
      @retries = 0

      @scheduler = Rufus::Scheduler.new

      logger.info('DevBot') { "Token: #{@token.inspect}" }
      logger.info('DevBot') { "Dev bot is disabled" } unless @run
    end
    attr_accessor :logger, :bot

    def run
      return unless @run
      unless @token
        logger.warn('DevBot') { "Token for statistics bot is not set! It won't run." }
        return
      end

      logger.info('DevBot') { "Scheduling statistics sending..." }
      @scheduler.cron("0 6 * * *") { send_general_statistics }
      @scheduler.cron("0 18 * * *") { send_general_statistics }

      logger.info('DevBot') { "Starting statistics bot..." }
      Telegram::Bot::Client.run(@token) do |bot|
        logger.info('DevBot') { "Bot is running." }
        @bot = bot
        begin
          bot.api.set_my_commands commands: MY_COMMANDS
          bot.listen { handle_message it }
        rescue Telegram::Bot::Exceptions::ResponseError => e
          logger.error('DevBot') { "Telegram API error: #{e.detailed_message}" }
          logger.error('DevBot') { "Retrying..." }
          retry
        rescue => e
          logger.error('DevBot') { "Unhandled error in bot listen loop: #{e.detailed_message}" }
          logger.error('DevBot') { "Backtrace: #{e.backtrace.join("\n")}" }
          logger.error('DevBot') { "Retrying..." }
          retry
        end
      end
    rescue Interrupt
      puts
      logger.warn('DevBot') { "Keyboard interruption" }
    rescue => e
      logger.error('DevBot') { "Unhandled error in bot main method: #{e.detailed_message}" }
      logger.error('DevBot') { "Backtrace: #{e.backtrace.join("\n")}" }
      logger.error('DevBot') { "Retrying..." }

      sleep 5
      retries += 1
      retry if retries < MAX_RETRIES
      "Reached maximum retries! Stopping dev bot...".tap do |msg|
        report "FATAL ERROR: #{msg}", log: 20
        logger.fatal('DevBot') { msg }
      end
    ensure
      File.write(ADMIN_CHAT_ID_FILE, @admin_chat_id.to_s) if @admin_chat_id
    end

    def report text, photo: nil, backtrace: nil, log: nil
      return unless @token && @admin_chat_id && @run

      logger.info('DevBot') { "Sending report #{text.inspect}..." }
      bot.api.send_photo(chat_id: @admin_chat_id, photo:) if photo
      send_log(lines: log) if log
      if backtrace
        bot.api.send_message(
          chat_id: @admin_chat_id,
          text: "BACKTRACE:\n```\n#{backtrace}\n```",
          parse_mode: 'Markdown'
        )
      end
      bot.api.send_message(chat_id: @admin_chat_id, text:)
    rescue Telegram::Bot::Exceptions::ResponseError => e
      logger.error('DevBot') { "Telegram API error in `#report`: #{e.detailed_message}" }
      logger.error('DevBot') { "BACKTRACE:\n#{e.backtrace.join("\n")}" }
    end

    private

    def handle_message message
      case message.text.downcase
      when '/start' then @admin_chat_id = message.chat.id
      when ->(*) { @admin_chat_id.nil? } then return
      when %r(/log\s+(\d+)) then send_log lines: Regexp.last_match(1).to_i
      when '/log' then send_log
      when '/general' then send_general_statistics
      when '/departments' then send_departments message
      when '/groups' then send_groups message
      when '/configuration' then send_configuration_statistics message
      when '/commands' then send_commands_statistics message
      # TODO: /commands DAYS
      when '/update_statistics_cache' then collect_statistics cache: false
      when '/new_chats' then send_new_users message
      when %r(/new_chats\s+(\d+)) then send_new_users message, days: Regexp.last_match(1).to_i
      when %r(/notify_all\s+(.+)) then send_notification_to_all_users message.text.match(%r(/notify_all\s+(.+)))[1]
      else bot.api.send_message(chat_id: message.chat.id, text: "Huh?")
      end
    rescue => e
      bot.api.send_message(
        chat_id: @admin_chat_id, text: "Unlandled error in `#handle_message`: #{e.detailed_message}"
      )
      bot.api.send_message(
        chat_id: @admin_chat_id, text: "```\n#{e.backtrace.join("\n")}\n```", parse_mode: 'Markdown'
      )
    end

    def send_log lines: 20
      log = last_log(lines:)
      if log && !log.empty?
        bot.api.send_message(
          chat_id: @admin_chat_id,
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
      departments = collect_statistics[:departments]
        .transform_keys { it.to_s.ljust 14 }
        .transform_values do |groups|
          chats = groups.values.flatten
          [groups.size, chats.count(&:private?), chats.count(&:supergroup?)]
        end
        .sort_by(&:last).reverse

      text = departments.map { |k, v| '`%s (%2d groups, %2d PC, %2d GC)`' % ([k] + v) }.join("\n")
      bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
    end

    def send_groups message
      groups = collect_statistics[:groups]
        .transform_keys { DevBot.just_group it }
        .transform_values { [it.count(&:private?), it.count(&:supergroup?)] }
        .sort_by { |k, v| [v, k] }.reverse
      text = groups.map { |k, v| '`%15s (%2d PC, %2d GC)`' % ([k] + v) }.join("\n")
      bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
    end

    def send_general_statistics
      statistics = collect_statistics

      total_chats = statistics[:private_chats].size + statistics[:group_chats].size

      top_groups = statistics[:groups]
        .transform_values { [it.count(&:private?), it.count(&:supergroup?)] }
        .sort_by(&:last).reverse.first(3)
        .map { |k, v| "%s (%2d PC, %2d GC)" % ([DevBot.just_group(k)] + v) }
      top_departments = statistics[:departments]
        .transform_values do |groups|
          chats = groups.values.flatten
          [groups.size, chats.count(&:private?), chats.count(&:supergroup?)]
        end
        .sort_by(&:last).reverse.first(3)
        .map { |k, v| "%14s (%2s groups, %2d PC, %2d GC)" % ([k] + v) }

      day_commands = statistics[:command_usages]
        .map { |k, v| [k, v.select { Time.now - it[:timestamp] <= 24*60*60 }] }.to_h
      active_chats = day_commands.values.flatten.map { it[:user] }.uniq.size
      total_commands = day_commands.values.sum(&:size)
      schedule_commands = day_commands.slice(:week, :tomorrow, :left).values.sum(&:size)

      week_commands = statistics[:command_usages]
        .map { |k, v| [k, v.select { Time.now - it[:timestamp] <= 7*24*60*60 }] }.to_h
      active_chats_week = week_commands.values.flatten.map { it[:user] }.uniq.size
      total_commands_week = week_commands.values.sum(&:size)
      schedule_commands_week = week_commands.slice(:week, :tomorrow, :left).values.sum(&:size)

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

        New chats: #{statistics[:new_chats].size}
        (/new_chats)
        Active chats: #{active_chats}
        Total commands used: #{total_commands}
        Schedule commands used: #{schedule_commands}
        (/commands)

        LAST WEEK

        Active chats: #{active_chats_week}
        Total commands used: #{total_commands_week}
        Schedule commands used: #{schedule_commands_week}
      MARKDOWN
      bot.api.send_message(chat_id: @admin_chat_id, text:)
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
          DevBot.just_group(user.group_name)
        ]
      end.join("\n\n")

      text = "No new users for the period." if text.strip.empty?
      bot.api.send_message(chat_id: message.chat.id, text:, parse_mode: 'Markdown')
    end

    def send_configuration_statistics message
      statistics = collect_statistics

      daily_sending = statistics[:daily_sending_configuration].transform_keys(&:to_s)
        .sort_by(&:first).map do |time, users|
          groups = users.map(&:group_name).uniq.size
          "`%5s => %2s groups, %2s users`" % [time ? time : 'off', groups, users.size]
        end.join("\n")
      pair_sending = statistics[:pair_sending_configuration].map do |state, users|
        state = state.nil? ? 'nil' : state ? 'on' : 'off'
        groups = users.map(&:group_name).uniq.size
        "`%5s => %2s groups, %2s users`" % [state, groups, users.size]
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
        departments: {}, # department => {group => chats}
        new_chats: [], # for last 24 hours
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
        (user.private? ? statistics[:private_chats] : statistics[:group_chats]) << user

        statistics[:groups][user.group_name] ||= []
        statistics[:groups][user.group_name] << user

        statistics[:departments][user.department_name] ||= {}
        statistics[:departments][user.department_name][user.group_name] ||= []
        statistics[:departments][user.department_name][user.group_name] << user

        statistics[:daily_sending_configuration][user.daily_sending] ||= []
        statistics[:daily_sending_configuration][user.daily_sending] << user

        statistics[:pair_sending_configuration][user.pair_sending] ||= []
        statistics[:pair_sending_configuration][user.pair_sending] << user

        if user.statistics[:start].then { it && it >= Time.now - 24*60*60 }
          statistics[:new_chats] << user
        end

        commands_statistics = Cache
          .fetch(:"command_usage_statistics_#{user.id}", expires_in: (cache ? 10*60 : 0), log: false) do
            user.statistics[:last_commands].map { it.merge({user: user}) }.group_by do |usage|
              text = usage[:command].downcase.then do
                it.end_with?("@#{bot_name}") ? it.match(/^(.*)@#{bot_name}$/).match(1) : it
              end

              case text
              when '/week', Bot::LABELS[:week].downcase then :week
              when '/tomorrow', Bot::LABELS[:tomorrow].downcase then :tomorrow
              when '/left', Bot::LABELS[:left].downcase then :left
              when '/set_group', Bot::LABELS[:select_group].downcase then :config_group
              when '/configure_sending', Bot::LABELS[:configure_sending].downcase then :config_sending
              when '/configure_daily_sending', Bot::LABELS[:daily_sending].downcase then :daily_sending
              when '/pair_sending_on', Bot::LABELS[:pair_sending_on].downcase then :pair_sending_on
              when '/pair_sending_off', Bot::LABELS[:pair_sending_off].downcase then :pair_sending_off
              else :other
              end
            end
          end

        statistics[:command_usages].each { |k, v| v.push(*commands_statistics[k]) }
      end

      logger.debug "Statistics collection took #{Time.now - start_time} seconds"

      statistics
    end

    def send_notification_to_all_users text
      count = 0
      User.users.each_value do |user|
        @main_bot.send_message chat_id: user.id, text:, parse_mode: 'Markdown'
        count += 1
      rescue Telegram::Bot::Exceptions::ResponseError => e
        logger.error('DevBot') { "Failed to send message to ##{user.id}: #{e.detailed_message}" }
      end
      report "Successfully sent notification to #{count} chats."
    end

    def self.just_group group
      return '' if group.nil? || group.empty?

      if group =~ /^(\S+)-(\d+)-\((\d+)\)-(\d+)$/
        prefix, year, num, suffix = $1, $2, $3, $4
        "#{prefix.ljust(5)}-#{year}-(%2d)-#{suffix}" % num.to_i
      else group
      end
    end
  end
end
