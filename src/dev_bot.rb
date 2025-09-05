# frozen_string_literal: true

require 'json'
require 'rufus-scheduler'
require 'telegram/bot'

require_relative 'user'

module Raspishika
  class DevBot
    TOKEN_FILE = File.expand_path('config/token_dev', ROOT_DIR)
    ADMIN_CHAT_ID_FILE = File.expand_path('../data/admin_chat_id', __dir__).freeze
    MY_COMMANDS = [
      { command: 'log', description: 'Get last log' },
      { command: 'general', description: 'Get general statistics' },
      { command: 'groups', description: 'Get groups statistics' },
      { command: 'departments', description: 'Get departments statistics' },
      { command: 'new_chats', description: 'Get new users for last N=1 hours' },
      { command: 'commands', description: 'Get commands usage statistics for last 24 hours' },
      { command: 'configuration', description: 'Get configuration statistics' },
      { command: 'help', description: 'No help' }
    ].freeze

    def initialize(main_bot:, logger: nil)
      @main_bot = main_bot

      @logger = logger || ::Logger.new($stderr, level: ::Logger::ERROR)
      @token = OPTIONS[:dev_token] || begin
        File.read('config/token_dev').chomp
      rescue Errno::ENOENT
        logger.error 'No `config/token_dev` file found.'
        logger.warn "The dev bot won't run."
      end
      @admin_chat_id = begin
        File.read(ADMIN_CHAT_ID_FILE).chomp.to_i
      rescue StandardError
        nil
      end
      logger.info('DevBot') { "Admin chat ID: #{@admin_chat_id.inspect}" }

      @run = OPTIONS[:dev_bot]
      @retries = 0

      @scheduler = Rufus::Scheduler.new

      logger.info('DevBot') { "Token: #{@token.inspect}" }
      logger.info('DevBot') { 'Dev bot is disabled' } unless @run
    end
    attr_accessor :logger, :bot
    attr_reader :admin_chat_id

    def run
      return unless @run

      unless @token
        logger.warn('DevBot') { "Token for statistics bot is not set! It won't run." }
        return
      end

      logger.info('DevBot') { 'Scheduling statistics sending...' }
      @scheduler.cron('0 6 * * *') { send_general_statistics }
      @scheduler.cron('0 18 * * *') { send_general_statistics }

      logger.info('DevBot') { 'Starting statistics bot...' }
      Telegram::Bot::Client.run(@token) do |bot|
        logger.info('DevBot') { 'Bot is running.' }
        @bot = bot
        begin
          bot.api.set_my_commands commands: MY_COMMANDS
          bot.listen { handle_message it }
        rescue Telegram::Bot::Exceptions::ResponseError => e
          logger.error('DevBot') { "Telegram API error: #{e.detailed_message}" }
          logger.error('DevBot') { 'Retrying...' }
          retry
        rescue StandardError => e
          logger.error('DevBot') { "Unhandled error in bot listen loop: #{e.detailed_message}" }
          logger.error('DevBot') { "Backtrace: #{e.backtrace.join("\n")}" }
          logger.error('DevBot') { 'Retrying...' }
          retry
        end
      end
    rescue Interrupt
      puts
      logger.warn('DevBot') { 'Keyboard interruption' }
    rescue StandardError => e
      logger.error('DevBot') { "Unhandled error in bot main method: #{e.detailed_message}" }
      logger.error('DevBot') { "Backtrace: #{e.backtrace.join("\n")}" }
      logger.error('DevBot') { 'Retrying...' }

      sleep 5
      retries += 1
      retry if retries < MAX_RETRIES

      'Reached maximum retries! Stopping dev bot...'.tap do |msg|
        report "FATAL ERROR: #{msg}", log: 20
        logger.fatal('DevBot') { msg }
      end
    ensure
      File.write(ADMIN_CHAT_ID_FILE, @admin_chat_id.to_s) if @admin_chat_id
    end

    def report(text, photo: nil, backtrace: nil, log: nil)
      return unless @token && @admin_chat_id && @run

      logger.info('DevBot') { "Sending report #{text.inspect}..." }
      bot.api.send_photo(chat_id: @admin_chat_id, photo: photo) if photo
      send_log(lines: log) if log
      if backtrace
        bot.api.send_message(
          chat_id: @admin_chat_id,
          text: "BACKTRACE:\n```\n#{backtrace}\n```",
          parse_mode: 'Markdown'
        )
      end
      bot.api.send_message(chat_id: @admin_chat_id, text: text, parse_mode: 'Markdown')
    rescue Telegram::Bot::Exceptions::ResponseError => e
      logger.error('DevBot') { "Telegram API error in `#report`: #{e.detailed_message}" }
      logger.error('DevBot') { "BACKTRACE:\n#{e.backtrace.join("\n")}" }
    end

    private

    def handle_message(message)
      return unless message.chat.id == admin_chat_id

      case message.text.downcase
      when %r{/log\s+(\d+)} then send_log lines: Regexp.last_match(1).to_i
      when '/log' then send_log
      when '/general' then send_general_statistics
      when '/departments' then send_departments
      when %r{/groups\s+(\d+)} then send_groups limit: Regexp.last_match(1).to_i
      when '/groups' then send_groups
      when '/configuration' then send_configuration_statistics
      when '/commands' then send_commands_statistics
      # TODO: /commands DAYS
      when '/new_chats' then send_new_chats
      when %r{/new_chats\s+(\d+)} then send_new_chats days: Regexp.last_match(1).to_i
      when %r{/notify_all\s+(.+)} then send_notification_to_all_users Regexp.last_match(1)
      else bot.api.send_message(chat_id: admin_chat_id, text: 'Huh?')
      end
    rescue StandardError => e
      bot.api.send_message(
        chat_id: admin_chat_id, text: "Unlandled error in `#handle_message`: #{e.detailed_message}"
      )
      bot.api.send_message(
        chat_id: admin_chat_id, text: "```\n#{e.backtrace.join("\n")}\n```", parse_mode: 'Markdown'
      )
    end

    def send_log(lines: 20)
      log = last_log(lines: lines)
      if log && !log.empty?
        bot.api.send_message(
          chat_id: admin_chat_id,
          text: "```\n#{log}\n```",
          parse_mode: 'Markdown'
        )
      else
        bot.api.send_message(chat_id: admin_chat_id, text: 'No log.')
      end
    end

    def last_log(lines: 20)
      File.exist?(logger.log_file) ? `tail -n #{lines} #{logger.log_file.shellescape}` : ''
    rescue StandardError => e
      "Failed to get last log: #{e.detailed_message}".tap do
        logger.error it
        report it
      end
      ''
    end

    def send_departments
      departments = collect_statistics[:departments].transform_keys { it.to_s.sub('Отделение ', '').rstrip.ljust(4) }
      departments.transform_values! do |groups|
        chats = groups.values.flatten
        [groups.size, chats.count(&:private?), chats.count(&:supergroup?)]
      end
      departments = departments.sort_by(&:last).reverse

      text = <<~MARKDOWN
        Total departments: #{departments.size}

        #{departments.map { |k, v| format('`%s (%2d G, %2d PC, %2d GC)`', k, *v) }.join("\n")}
      MARKDOWN
      bot.api.send_message(chat_id: @admin_chat_id, text: text, parse_mode: 'Markdown')
    end

    def send_groups(limit: nil)
      groups = collect_statistics[:groups]
               .transform_keys { DevBot.just_group it }
               .transform_values { [it.count(&:private?), it.count(&:supergroup?)] }
               .sort_by { |k, v| [v, k] }.reverse
      groups = groups.first limit if limit

      text = <<~MARKDOWN
        Total groups: #{groups.size}

        #{groups.map { |k, v| format('`%15s (%2d PC, %2d GC)`', k, *v) }.join("\n")}
      MARKDOWN
      bot.api.send_message(chat_id: @admin_chat_id, text: text, parse_mode: 'Markdown')
    end

    def send_general_statistics
      statistics = collect_statistics

      total_chats = statistics[:private_chats].size + statistics[:group_chats].size
      top_groups = statistics[:groups].transform_values { [it.count(&:private?), it.count(&:supergroup?)] }
                                      .sort_by(&:last).reverse.first(5)
      top_groups.map! { |k, v| format('`%s (%2d PC, %2d GC)`', DevBot.just_group(k), *v) }

      day_commands =
        statistics[:command_usages].transform_values { |v| v.select { Time.now - it[:timestamp] <= 24 * 60 * 60 } }
      active_chats = day_commands.values.flatten.map { it[:user] }.uniq.size
      total_ok_commands = day_commands.values.sum { it.count { it[:ok] } }
      total_fail_commands = day_commands.values.sum { it.count { !it[:ok] } }
      schedule_commands = day_commands.slice(:week, :tomorrow, :left).values.sum(&:size)

      week_commands =
        statistics[:command_usages].transform_values { |v| v.select { Time.now - it[:timestamp] <= 7 * 24 * 60 * 60 } }
      active_chats_week = week_commands.values.flatten.map { it[:user] }.uniq.size
      total_ok_commands_week = week_commands.values.sum { it.count { it[:ok] } }
      total_fail_commands_week = week_commands.values.sum { it.count { !it[:ok] } }
      schedule_commands_week = week_commands.slice(:week, :tomorrow, :left).values.sum(&:size)

      bot.api.send_message(chat_id: admin_chat_id, parse_mode: 'Markdown', text: <<~MARKDOWN)
        GENERAL

        Total chats: #{total_chats}
        Private chats: #{statistics[:private_chats].size}
        Group chats: #{statistics[:group_chats].size}

        Total groups: #{statistics[:groups].size}
        Top 5 groups by students:
        #{top_groups.join "\n"}
        (/groups)

        Total departments: #{statistics[:departments].size}
        (/departments)
      MARKDOWN
      bot.api.send_message(chat_id: admin_chat_id, parse_mode: 'Markdown', text: <<~MARKDOWN)
        LAST 24 HOURS

        New chats: #{statistics[:new_chats].size}
        (/new\\_chats)
        Active chats: #{active_chats}
        Total commands used: #{total_ok_commands} ok + #{total_fail_commands} fail
        Schedule commands used: #{schedule_commands}
        (/commands)
      MARKDOWN
      bot.api.send_message(chat_id: admin_chat_id, parse_mode: 'Markdown', text: <<~MARKDOWN)
        LAST WEEK

        Active chats: #{active_chats_week}
        Total commands used: #{total_ok_commands_week} ok + #{total_fail_commands_week} fail
        Schedule commands used: #{schedule_commands_week}
      MARKDOWN
    end

    def send_new_chats(days: 1)
      chats =
        if days.zero?
          User.users.values
        else
          User.users.values.select do |user|
            user.statistics[:start] && user.statistics[:start] >= Time.now - days * 24 * 60 * 60
          end
        end

      chats_by_year = chats.group_by { it.group_name&.match(/.+-(\d\d)-\(\d+\)-\d+/)&.[](1) }.map do |k, v|
        "`#{k} => #{v.size.to_s.rjust(2)}, #{v.group_by(&:group_name).size.to_s.rjust(2)} groups`"
      end
      chats_by_group = chats.group_by(&:group_name).sort_by { |_, v| v.size }.reverse.map do |k, v|
        "`#{DevBot.just_group(k)} => #{v.size.to_s.rjust(2)}`"
      end

      text = <<~MARKDOWN
        Total new chats for #{days} days: #{chats.size}
        Total groups: #{chats_by_group.size}

        #{chats_by_year.sort.join("\n")}

        #{chats_by_group.join("\n")}
      MARKDOWN

      text = 'No new chats for the period.' if text.strip.empty?
      bot.api.send_message(chat_id: @admin_chat_id, text: text, parse_mode: 'Markdown')
    end

    def send_configuration_statistics
      statistics = collect_statistics

      daily_sending = statistics[:daily_sending_configuration].transform_keys(&:to_s).sort_by(&:first).map do |t, users|
        groups = users.map(&:group_name).uniq.size
        "`#{(t.to_s || 'off').ljust(5)} => #{groups.to_s.rjust(3)} groups, #{users.size.to_s.rjust(3)} chats`"
      end
      pair_sending = statistics[:pair_sending_configuration].map do |state, users|
        state =
          if state.nil?
            'nil'
          else
            state ? 'on' : 'off'
          end
        groups = users.map(&:group_name).uniq.size
        "`#{state.to_s.ljust(3)} => #{groups.to_s.rjust(3)} groups, #{users.size.to_s.rjust(3)} chats`"
      end

      text = <<~MARKDOWN
        Pair sending configurations:

        #{pair_sending.join("\n")}

        Daily sending configurations:

        #{daily_sending.join("\n")}
      MARKDOWN
      bot.api.send_message(chat_id: admin_chat_id, text: text, parse_mode: 'Markdown')
    end

    def send_commands_statistics
      statistics = collect_statistics

      text = statistics[:command_usages].map do |k, v|
        "`#{k.to_s.ljust(24)} => #{v.size.to_s.rjust(5)}`"
      end.join("\n")
      bot.api.send_message(chat_id: admin_chat_id, text: text, parse_mode: 'Markdown')
    end

    def collect_statistics
      logger.info 'Collecting statistics...'
      start_time = Time.now

      statistics = {
        private_chats: [],
        group_chats: [],
        groups: {}, # group => chats
        departments: {}, # department => {group => chats}
        new_chats: [], # for last 24 hours
        daily_sending_configuration: {}, # time => chats
        pair_sending_configuration: {}, # state(nil,false,true) => chats
        command_usages: {
          help: [],
          week: [],
          tomorrow: [],
          left: [],
          quick_schedule: [],
          teacher_schedule: [],
          set_group: [],
          configure_daily_sending: [],
          settings: [],
          other: []
        }
      }
      bot_name = bot.api.get_me.username.downcase
      User.users.each_value do |user|
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

        statistics[:new_chats] << user if user.statistics[:start].then { it && it >= Time.now - 24 * 60 * 60 }

        commands_statistics = collect_commands_statistics user, bot_name
        commands_statistics.each do |k, v|
          statistics[:command_usages][k] ||= []
          statistics[:command_usages][k] += v
        end
      end

      logger.debug "Statistics collection took #{Time.now - start_time} seconds"

      statistics
    end

    def collect_commands_statistics(user, bot_name)
      user.statistics[:last_commands].map { it.merge({ user: user }) }.group_by do |usage|
        text = usage[:command].downcase.then do
          it.end_with?("@#{bot_name}") ? it.match(/^(.*)@#{bot_name}$/).match(1) : it
        end

        case text
        when '/help'                         then :help

        when '/week'                         then :week
        when '/tomorrow'                     then :tomorrow
        when '/left'                         then :left

        when '/quick_schedule'               then :quick_schedule
        when '/teacher_schedule'             then :teacher_schedule

        when '/set_group'                    then :set_group
        when '/configure_daily_sending'      then :configure_daily_sending

        when '/settings', Bot::LABELS[:settings].downcase then :settings
        else :other
        end
      end
    end

    def send_notification_to_all_users(text)
      count = 0
      User.users.each_value do |user|
        @main_bot.send_message chat_id: user.id, text: text, parse_mode: 'Markdown'
        count += 1
      rescue Telegram::Bot::Exceptions::ResponseError => e
        logger.error('DevBot') { "Failed to send message to ##{user.id}: #{e.detailed_message}" }
      end
      report "Successfully sent notification to #{count} chats."
    end

    def self.just_group(group)
      return '' if group.nil? || group.empty?

      if group =~ /^(\S+)-(\d+)-\((\d+)\)-(\d+)$/
        prefix = ::Regexp.last_match(1)
        year = ::Regexp.last_match(2)
        num = ::Regexp.last_match(3)
        suffix = ::Regexp.last_match(4)
        format("#{prefix.ljust(5)}-#{year}-(%2d)-#{suffix}", num.to_i)
      else
        group
      end
    end
  end
end
