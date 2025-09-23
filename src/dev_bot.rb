# frozen_string_literal: true

require 'json'
require 'rufus-scheduler'
require 'telegram/bot'

require_relative 'database'
require_relative 'logger'

module Raspishika
  class DevBot
    include GlobalLogger

    MY_COMMANDS = [
      { command: 'chat', description: 'Get statistics for a chat with given chat ID of username' },
      { command: 'general', description: 'Get general statistics' },
      { command: 'groups', description: 'Get groups statistics' },
      { command: 'departments', description: 'Get departments statistics' },
      { command: 'new_chats', description: 'Get new chats for last N=1 days' },
      { command: 'commands', description: 'Get commands usage statistics for last N=1 days' },
      { command: 'config', description: 'Get config statistics' },
      { command: 'log', description: 'Get last log' },
      { command: 'help', description: 'No help' }
    ].freeze
    GROUP_RE = /(\p{L}{2,5})[- ]?(\d{2})[- ]?\(?(9|11)\)?[- ]?(\d)/.freeze
    TIME_ARG_RE = /(\d+)([mhdw])?/.freeze

    def initialize(main_bot:)
      @main_bot = main_bot

      @token = Config[:dev_bot][:token]
      @admin_chat_id = Config[:dev_bot][:admin_chat_id]
      logger.info('DevBot') { "Admin chat ID: #{@admin_chat_id.inspect}" }

      @run = Config[:dev_bot][:enabled]
      @retries = 0

      @scheduler = Rufus::Scheduler.new

      logger.info('DevBot') { "Token: #{@token.inspect}" }
      logger.info('DevBot') { 'Dev bot is disabled' } unless @run
    end
    attr_accessor :bot
    attr_reader :admin_chat_id

    def run
      return unless @run

      unless @token
        logger.warn('DevBot') { "Token for statistics bot is not set! It won't run." }
        return
      end

      logger.info('DevBot') { 'Scheduling statistics sending...' }
      @scheduler.cron('0 6/12 * * *') { send_general_statistics }

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
    end

    def report(text, photo: nil, backtrace: nil, log: nil, markdown: false, code: false) # rubocop:disable Metrics/ParameterLists
      return unless @token && @admin_chat_id && @run

      bot.api.send_photo(chat_id: @admin_chat_id, photo: photo) if photo
      send_log(lines: log) if log
      send_backtrace backtrace if backtrace
      text = code ? "```\n#{text}\n```" : text
      bot.api.send_message(chat_id: @admin_chat_id, text: text, parse_mode: markdown || code ? 'Markdown' : nil)
    rescue Telegram::Bot::Exceptions::ResponseError => e
      logger.error('DevBot') { "Telegram API error in `#report`: #{e.detailed_message}" }
      logger.error('DevBot') { "BACKTRACE: #{e.backtrace.join("\n\t")}" }
    end

    private

    def send_backtrace(backtrace)
      bot.api.send_message(chat_id: @admin_chat_id, text: "BACKTRACE:\n```\n#{backtrace}\n```", parse_mode: 'Markdown')
    rescue Telegram::Bot::Exceptions::ResponseError => e
      case e.error_code
      when 400
        if e.message =~ /message is too long/
          backtrace.lines.each_slice(20) do |part|
            bot.api.send_message(chat_id: @admin_chat_id, text: "BACKTRACE:\n```\n#{part.join}\n```",
                                 parse_mode: 'Markdown')
          end
        end
      end
    end

    def handle_message(message)
      return unless message.chat.id == admin_chat_id

      case message.text.downcase
      when %r{/log\s+(\d+)} then send_log lines: Regexp.last_match(1).to_i
      when '/log' then send_log
      when '/general' then send_general_statistics
      when '/departments' then send_departments
      when %r{/group\s+(.+)} then send_group_stats group: Regexp.last_match(1)
      when '/groups' then send_groups
      when %r{/groups\s+(\d+)} then send_groups limit: Regexp.last_match(1).to_i
      when '/config' then send_config_statistics
      when '/commands' then send_commands_statistics
      when '/perfomance' then send_perfomans_stats
      when %r{/perfomance\s+(#{TIME_ARG_RE})} then send_perfomans_stats parse_time_arg Regexp.last_match(1)
      when %r{/commands\s+(\d+)} then send_commands_statistics days: Regexp.last_match(1).to_i
      when '/new_chats' then send_new_chats
      when %r{/new_chats\s+(\d+)} then send_new_chats days: Regexp.last_match(1).to_i
      when %r{/chat\s+(.+)} then send_chat_statistics Regexp.last_match(1)
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

    def parse_time_arg(str, default_masure: 'h')
      m = str.match(TIME_ARG_RE)
      return unless m

      a =
        case m[2]
        when 'm' then 60 # Minutes
        when 'h' then 60 * 60 # Hours
        when 'd' then 24 * 60 * 60 # Days
        when 'w' then 7 * 24 * 60 * 60 # Weeks
        end
      m[1].to_i * a
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
        report it, code: true
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

        #{departments.map { |k, v| format('`%s => %2d G, %2d PC, %2d GC`', k, *v) }.join("\n")}
      MARKDOWN
      bot.api.send_message(chat_id: @admin_chat_id, text: text, parse_mode: 'Markdown')
    end

    def send_group_stats(group: nil)
      return unless group

      all_groups = @main_bot.parser.fetch_all_groups.values.inject(&:merge).keys
      group = DevBot.normalize_group_name all_groups, group
      return unless group

      chats = Chat.where group: group

      bot.api.send_message(chat_id: @admin_chat_id, text: <<~MARKDOWN, parse_mode: 'Markdown')
        *Group:* #{group}
        *Private chats:* #{chats.count(&:private?)}

        #{chats.select(&:private?).map { "`/chat #{it.tg_id}` @#{it.username}" }.join("\n")}

        *Group chats:* #{chats.count(&:supergroup?)}

        #{chats.select(&:supergroup?).map { "`/chat #{it.tg_id}` @#{it.username}" }.join("\n")}
      MARKDOWN
    end

    def send_groups(limit: nil)
      groups = collect_statistics[:groups]
               .transform_keys { DevBot.just_group it }
               .transform_values { [it.count(&:private?), it.count(&:supergroup?)] }
               .sort_by { |k, v| [v, k] }.reverse
      groups = groups.first limit if limit

      text = <<~MARKDOWN
        *Total groups:* #{groups.size}

        ```
        #{groups.map { |g, v| "#{g.ljust(15)} => #{v[0].to_s.rjust(2)} PC, #{v[1].to_s.rjust(2)} GC" }.join("\n")}
        ```
      MARKDOWN
      bot.api.send_message(chat_id: @admin_chat_id, text: text, parse_mode: 'Markdown')
    end

    def send_general_statistics
      statistics = collect_statistics

      total_chats = statistics[:private_chats].size + statistics[:group_chats].size
      top_groups = Chat.all.group_by(&:group).transform_values do |chats|
        cphs = chats.map do |c|
          # Commands per hour
          c.command_usages.where(created_at: (Time.now - 7 * 24 * 60 * 60)..Time.now).count.to_f / 7 * 24
        end
        cphs.sum.to_f / cphs.size
      end.sort_by { |_, cph| cph }.reverse.first(5)
      top_groups.map! { |g, cph| "#{DevBot.just_group(g)} => #{cph} CPH" }

      day_commands = CommandUsage.where(created_at: (Time.now - 24 * 60 * 60)..Time.now)
      active_chats = day_commands.map(&:chat_id).uniq.size
      total_ok_commands = day_commands.where(successful: true).count
      total_fail_commands = day_commands.where(successful: false).count
      schedule_commands = day_commands.where("command IN ('/week', '/tomorrow', '/left')").count

      week_commands = CommandUsage.where(created_at: (Time.now - 7 * 24 * 60 * 60)..Time.now)
      active_chats_week = week_commands.map(&:chat_id).uniq.size
      total_ok_commands_week = week_commands.where(successful: true).count
      total_fail_commands_week = week_commands.where(successful: false).count
      schedule_commands_week = week_commands.where("command IN ('/week', '/tomorrow', '/left')").count

      bot.api.send_message(chat_id: admin_chat_id, parse_mode: 'Markdown', text: <<~MARKDOWN)
        *GENERAL*

        *Total chats:* #{total_chats}
        *Private chats:* #{statistics[:private_chats].size}
        *Group chats:* #{statistics[:group_chats].size}

        *Total groups:* #{statistics[:groups].size}
        *Top 5 groups by activeness:*
        ```
        #{top_groups.join "\n"}
        ```
        (/groups)
        (/departments)
      MARKDOWN
      bot.api.send_message(chat_id: admin_chat_id, parse_mode: 'Markdown', text: <<~MARKDOWN)
        *LAST 24 HOURS*

        *New chats:* #{statistics[:new_chats].size}
        (/new\\_chats)
        *Active chats:* #{active_chats}
        *Total commands used:* #{total_ok_commands} ok + #{total_fail_commands} fail
        *Schedule commands used:* #{schedule_commands}
        (/commands)
      MARKDOWN
      bot.api.send_message(chat_id: admin_chat_id, parse_mode: 'Markdown', text: <<~MARKDOWN)
        *LAST WEEK*

        *Active chats:* #{active_chats_week}
        *Total commands used:* #{total_ok_commands_week} ok + #{total_fail_commands_week} fail
        *Schedule commands used:* #{schedule_commands_week}
      MARKDOWN
    end

    def send_new_chats(days: 1)
      chats = days.zero? ? Chat.all : Chat.where(created_at: (Time.now - days * 24 * 60 * 60)..Time.now)

      chats_by_year = chats.group_by { it.group&.match(/.+-(\d\d)-\(\d+\)-\d+/)&.[](1) }.map do |k, v|
        "`#{k} => #{v.size.to_s.rjust(2)}, #{v.group_by(&:group).size.to_s.rjust(2)} groups`"
      end
      chats_by_group = chats.group_by(&:group).sort_by { |_, v| v.size }.reverse.map do |k, v|
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

    def send_config_statistics
      statistics = collect_statistics

      daily_sending = statistics[:daily_sending_configuration].transform_keys(&:to_s).sort_by(&:first).map do |t, chats|
        groups = chats.map(&:group).uniq.size
        "`#{(t.to_s || 'off').ljust(5)} => #{groups.to_s.rjust(3)} groups, #{chats.size.to_s.rjust(3)} chats`"
      end
      pair_sending = statistics[:pair_sending_configuration].map do |state, chats|
        state = state.nil? && 'nil' || state && 'on' || 'off'
        groups = chats.map(&:group).uniq.size
        "`#{state.to_s.ljust(3)} => #{groups.to_s.rjust(3)} groups, #{chats.size.to_s.rjust(3)} chats`"
      end

      text = <<~MARKDOWN
        PAIRS

        #{pair_sending.join("\n")}

        DAILY

        Total enabled: #{statistics[:daily_sending_configuration].select { |k, _| k }.each_value.sum(&:size)}

        #{daily_sending.join("\n")}
      MARKDOWN
      bot.api.send_message(chat_id: admin_chat_id, text: text, parse_mode: 'Markdown')
    end

    def send_commands_statistics(days: 7)
      command_usages =
        if days.zero?
          CommandUsage.all
        else
          CommandUsage.where(created_at: (Time.now - days * 24 * 60 * 60)..Time.now)
        end
      command_usages = command_usages.group_by(&:command).sort_by(&:first)

      text = command_usages.map { |k, u| "`#{k.to_s.ljust(20)} => #{u.size.to_s.rjust(5)}`" }.join("\n")
      bot.api.send_message(chat_id: admin_chat_id, text: text, parse_mode: 'Markdown')
    end

    def send_perfomans_stats(period = 24 * 60 * 60)
      commands = period.zero? ? CommandUsage.all : CommandUsage.where(created_at: (Time.now - period)..)
      avg_response_time_by_command = commands.group(:command).average(:response_time)
      mins = period / 60
      hours = mins / 60
      days = hours / 24
      send_message text: <<~MARKDOWN, parse_mode: 'Markdown'
        *Average response time for each command (last #{period}s/#{mins}m/#{hours}h/#{days}d):*

        ```
        #{avg_response_time_by_command.map { |c, a| "#{c} => #{a}" }.join("\n")}
        ```
      MARKDOWN
    end

    def send_chat_statistics(id_or_username)
      chat_data =
        if id_or_username =~ /-?\d+/
          Chat.where(tg_id: id_or_username).first
        else
          Chat.where('LOWER(username) = ?', id_or_username.sub('@', '')).first
        end

      if chat_data.nil?
        bot.api.send_message(chat_id: admin_chat_id, text: "Chat not found: #{id_or_username}")
        return
      end

      chat = @main_bot.bot.api.get_chat chat_id: chat_data.tg_id
      full_name = "#{chat.first_name&.escape_markdown} #{chat.last_name&.escape_markdown}".strip
      text = <<~MARKDOWN
        *Chat:* #{full_name} #{chat.title&.escape_markdown} @#{chat.username&.escape_markdown} ##{chat.id}
        *Department:* #{chat_data.department}
        *Group:* #{chat_data.group}
        *Daily sending:* #{chat_data.daily_sending_time}
        *Pair sending:* #{chat_data.pair_sending}
      MARKDOWN
      bot.api.send_message(chat_id: admin_chat_id, text: text, parse_mode: 'Markdown')
    end

    def send_message(**kwargs)
      bot.api.send_message chat_id: @admin_chat_id, **kwargs
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
        pair_sending_configuration: {} # state(nil,false,true) => chats
      }
      bot_name = bot.api.get_me.username.downcase
      Chat.all.each do |chat|
        (chat.private? ? statistics[:private_chats] : statistics[:group_chats]) << chat

        statistics[:groups][chat.group] ||= []
        statistics[:groups][chat.group] << chat

        statistics[:departments][chat.department] ||= {}
        statistics[:departments][chat.department][chat.group] ||= []
        statistics[:departments][chat.department][chat.group] << chat

        statistics[:daily_sending_configuration][chat.daily_sending_time] ||= []
        statistics[:daily_sending_configuration][chat.daily_sending_time] << chat

        statistics[:pair_sending_configuration][chat.pair_sending] ||= []
        statistics[:pair_sending_configuration][chat.pair_sending] << chat

        statistics[:new_chats] << chat if chat.created_at >= Time.now - 24 * 60 * 60
      end

      statistics[:command_usages] = collect_commands_statistics bot_name

      logger.debug "Statistics collection took #{Time.now - start_time} seconds"

      statistics
    end

    def collect_commands_statistics(bot_name)
      CommandUsage.all.group_by do |usage|
        text = usage.command.downcase.sub(/@#{bot_name}$/, '')

        case text
        when '/help'          then :help
        when '/week'          then :week
        when '/tomorrow'      then :tomorrow
        when '/left'          then :left
        when '/quick'         then :quick
        when '/teacher'       then :teacher
        when '/set_group'     then :set_group
        when '/daily_sending' then :daily_sending
        else :other
        end
      end
    end

    def self.normalize_group_name(all_groups, name)
      match = name&.match(GROUP_RE)
      return unless match

      normalized = "#{match[1].downcase}-#{match[2]}-(#{match[3]})-#{match[4]}"
      all_groups.find { it.downcase == normalized }
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
