# frozen_string_literal: true

require 'rufus-scheduler'
require 'telegram/bot'

require_relative 'logger'
require_relative 'parser'
require_relative 'dev_bot'
require_relative 'main_bot/debug_commands'
require_relative 'main_bot/general_commands'
require_relative 'main_bot/config_commands'
require_relative 'main_bot/schedule_commands'

class Telegram::Bot::Types::User
  def full_name
    "#{first_name} #{last_name}".strip
  end
end

module Raspishika
  class Bot
    TOKEN_FILE = File.expand_path('config/token', ROOT_DIR)
    TOKEN = OPTIONS[:token] || begin
      File.read(TOKEN_FILE).chomp
    rescue Errno::ENOENT => e
      logger.fatal e.detailed_message
      logger.fatal "Please provide a token in #{TOKEN_FILE} or use --token option."
      exit
    end
    THEAD_POOL_SIZE = 20

    LABELS = {
      left: 'Оставшиеся пары',
      tomorrow: 'Завтра',
      week: 'Неделя',

      quick_schedule: 'Быстрое расписание',
      select_group: 'Выбрать группу',
      settings: 'Настройки',

      other_group: 'Другая группа',
      teacher: 'Преподаватель',

      my_group: 'Моя группа',
      daily_sending: 'Ежедневная рассылка',
      pair_sending_on: 'Вкл. рассылку перед парами',
      pair_sending_off: 'Выкл. рассылку перед парами'
    }.freeze

    DEFAULT_KEYBOARD = [
      [LABELS[:left], LABELS[:tomorrow], LABELS[:week]],
      [LABELS[:quick_schedule], LABELS[:settings]]
    ].freeze
    DEFAULT_REPLY_MARKUP = {
      keyboard: DEFAULT_KEYBOARD,
      resize_keyboard: true,
      one_time_keyboard: true
    }.to_json.freeze

    MY_COMMANDS = [
      { command: 'left', description: 'Оставшиеся пары' },
      { command: 'tomorrow', description: 'Расписание на завтра' },
      { command: 'week', description: 'Расписание на неделю' },

      { command: 'quick_schedule', description: 'Расписание другой группы' },
      { command: 'teacher_schedule', description: 'Расписание преподавателя' },

      { command: 'configure_daily_sending', description: 'Настроить ежедневную рассылку' },
      { command: 'daily_sending_off', description: 'Выключить ежедневную рассылку' },

      { command: 'pair_sending_on', description: 'Включить рассылку перед парами' },
      { command: 'pair_sending_off', description: 'Выключить рассылку перед парами' },

      { command: 'set_group', description: 'Изменить группу' },

      { command: 'cancel', description: 'Отменить действие' },
      { command: 'stop', description: 'Остановить бота и удалить данные о себе' },
      { command: 'help', description: 'Помощь' },
      { command: 'start', description: 'Запуск бота' }
    ].freeze

    def initialize
      @logger = Raspishika::Logger.new
      @scheduler = Rufus::Scheduler.new
      @parser = Raspishika::ScheduleParser.new(logger: @logger)
      @thread_pool = Concurrent::FixedThreadPool.new THEAD_POOL_SIZE
      @retries = 0

      @token = TOKEN
      @run = true
      @dev_bot = DevBot.new main_bot: self, logger: @logger
      @username = nil

      ImageGenerator.logger = Cache.logger = User.logger = @logger
      User.load
    end
    attr_accessor :bot, :logger, :parser, :username

    def run
      logger.info 'Starting bot...'
      @user_backup_thread = Thread.new(self, &:users_save_loop)

      @dev_bot_thread = Thread.new(@dev_bot, &:run)

      @parser.initialize_browser_thread
      sleep 1 until @parser.ready?

      Telegram::Bot::Client.run(@token) do |bot|
        @bot = bot
        @username = bot.api.get_me.username
        logger.debug "Bot's username: #{@username}"

        report 'Bot started.'

        bot.api.set_my_commands(commands: MY_COMMANDS)

        schedule_pair_sending
        if OPTIONS[:daily]
          @sending_thread = Thread.new(self, &:daily_sending_loop)
        else
          logger.info 'Daily sending is disabled'
        end

        begin
          logger.info 'Starting bot listen loop...'
          bot.listen { |message| handle_message message }
        rescue Telegram::Bot::Exceptions::ResponseError => e
          "Telegram API error: #{e.detailed_message}".tap do |msg|
            report(msg, backtrace: e.backtrace.join("\n"), log: 20)
            logger.error msg
            logger.error "Retrying... (#{@retries + 1}/#{MAX_RETRIES})"
          end

          sleep 5
          @retries += 1
          retry if @retries < MAX_RETRIES
          'Reached maximum retries! Stopping bot...'.tap do |msg|
            report "FATAL ERROR: #{msg}", log: 20
            logger.fatal msg
          end
        rescue StandardError => e
          "Unhandled error in `bot.listen`: #{e.detailed_message}".tap do |msg|
            report(msg, backtrace: e.backtrace.join("\n"), log: 20)
            logger.error msg
            logger.error "Backtrace: #{e.backtrace.join("\n\t")}"
            logger.error "Retrying... (#{@retries + 1}/#{MAX_RETRIES})"
          end

          sleep 5
          @retries += 1
          retry if @retries < MAX_RETRIES
          'Reached maximum retries! Stopping bot...'.tap do |msg|
            report "FATAL ERROR: #{msg}", log: 20
            logger.fatal msg
          end
        end
      end
    rescue Interrupt
      puts
      logger.warn 'Keyboard interruption'
    rescue StandardError => e
      puts
      logger.fatal 'Unhandled error in the main method (#run):'
      logger.fatal e.detailed_message
      logger.fatal e.backtrace.join "\n"
    ensure
      shutdown
    end

    def shutdown
      report 'Bot stopped.'
      @run = false

      @user_backup_thread&.join
      User.save_all

      @dev_bot_thread&.kill
      @sending_thread&.join
      @parser.stop_browser_thread

      @thread_pool&.shutdown
      @thread_pool&.wait_for_termination(30)
      @thread_pool&.kill if @thread_pool.running?
    end

    def send_message(*args, **kwargs)
      @bot.api.send_message(*args, **kwargs)
    end

    def users_save_loop
      while @run
        User.save_all
        600.times do
          break unless @run

          sleep 1
        end
      end
    end

    def daily_sending_loop
      logger.info 'Starting daily sending loop...'
      last_sending_time = Time.now - 2 * 60

      while @run
        current_time = Time.now

        users_to_send = User.users.values.select do
          it.daily_sending && Time.parse(it.daily_sending).between?(last_sending_time, current_time)
        end

        futures = users_to_send.map do |user|
          Concurrent::Future.execute(executor: @thread_pool) do
            start_time = Time.now
            send_week_schedule(nil, user)
            user.push_daily_sending_report(
              conf_time: it.daily_sending, process_time: Time.now - start_time, ok: true
            )
          rescue StandardError => e
            user.push_daily_sending_report(
              conf_time: it.daily_sending, process_time: Time.now - start_time, ok: false
            )
            msg = "Error while sending daily schedule: #{e.detailed_message}"
            backtrace = e.backtrace.join("\n")
            report(msg, backtrace: backtrace)
            logger.error msg
            logger.error backtrace
          end
        end
        futures.each(&:wait)

        if users_to_send.any?
          logger.debug "Daily sending for #{users_to_send.size} users took #{Time.now - current_time} seconds"
        end

        last_sending_time = current_time

        60.times do
          break unless @run

          sleep 1
        end
      end
    end

    def schedule_pair_sending
      logger.info 'Scheduling pair sending...'

      ['8:00', '9:45', '11:30', '13:45', '15:30', '17:15', '19:00'].each do |time|
        logger.debug "Scheduling sending for #{time}..."
        time = Time.parse time

        sending_time = time - 15 * 60
        @scheduler.cron("#{sending_time.min} #{sending_time.hour} * * 1-6") do
          send_pair_notification time
        end
      end
    end

    def debug_command(message, user)
      return unless OPTIONS[:debug_commands]

      debug_command_name = message.text.split(' ').last
      logger.info "Calling test #{debug_command_name}..."
      unless DebugCommands.respond_to? debug_command_name
        logger.warn "Test #{debug_command_name} not found"
        bot.api.send_message(
          chat_id: message.chat.id,
          text:
            "Тест `#{debug_command_name}` не найден.\n\n" \
            "Доступные тесты: #{DebugCommands.methods.join(', ')}",
          reply_markup: default_reply_markup(user.id)
        )
        return
      end

      DebugCommands.send(debug_command_name, bot: self, user: user, message: message)
    end

    private

    def send_pair_notification(time, user: nil)
      logger.info "Sending pair notification for #{time}..."

      groups_data = @parser.fetch_all_groups @parser.fetch_departments
      groups =
        if user
          logger.debug "Sending pair notification for #{time} to #{user.id} with group #{user.group_info}..."
          { [user.department_name, user.group_name] => [user] }
        else
          User.users.values.select(&:pair_sending).group_by { [it.department_name, it.group_name] }
        end
      logger.debug "Sending pair notification to #{groups.size} groups..."

      futures = groups.map do |(_dname, gname), users|
        Concurrent::Future.execute(executor: @thread_pool) do
          send_pair_notification_for_group(users, time)
        rescue StandardError => e
          logger.error "Failed to send pair notification for #{gname}: #{e.detailed_message}"
          logger.error e.backtrace.join("\n\t")
        end
      end
      futures.each(&:wait)
    end

    def send_pair_notification_for_group(users, time)
      if users.empty?
        logger.warn 'Users array is empty'
        return
      end

      logger.info "Sending pair notification to #{users.size} users of group #{users.first.group_name}"

      raw_schedule = @parser.fetch_schedule users.first.group_info
      if raw_schedule.nil?
        logger.error "Failed to fetch schedule for #{users.first.group_info}"
        return
      end

      pair = Schedule.from_raw(raw_schedule).now(time: time)&.pair(0)
      return unless pair

      text =
        case pair.data.dig(0, :pairs, 0, :type)
        when :subject, :exam, :consultation
          format("Следующая пара в кабинете %<classroom>s:\n%<discipline>s\n%<teacher>s",
                 pair.data.dig(0, :pairs, 0, :content))
        else
          logger.debug 'No pairs left for the group'
          return
        end

      logger.debug "Sending pair notification to #{users.size} users of group #{users.first.group_name}..."
      users.map(&:id).each do |chat_id|
        bot.api.send_message(chat_id: chat_id, text: text)
      rescue StandardError => e
        logger.error "Failed to send pair notification of group #{users.first.group_name} to #{chat_id}:" \
                     "#{e.detailed_message}"
        logger.error e.backtrace.join("\n\t")
      end
    end

    def report(*args, **kwargs)
      @dev_bot.report(*args, **kwargs)
    end

    def handle_message(message)
      # Skip messages sent more than 1 hour ago.
      return if Time.at(message.date) < Time.now - 1 * 60 * 60

      case message
      when Telegram::Bot::Types::Message then handle_text_message message
      else logger.debug "Unhandled message type: #{message.class}"
      end
    end

    def handle_text_message(message)
      return unless message.text

      begin
        short_text = message.text.size > 32 ? "#{message.text[0...32]}…" : message.text
        logger.debug("[#{message.chat.id}] #{message.from.full_name} @#{message.from.username} ##{message.from.id} =>" \
                     " #{short_text.inspect}")

        user = User[message.chat.id]
        if message.text.downcase != '/start' && user.statistics[:start].nil?
          user.statistics[:start] = Time.now
          msg = "New user: #{message.chat.id}" \
            " (@#{message.from.username}, #{message.from.first_name} #{message.from.last_name})"
          logger.debug msg
          report msg
        end

        text = message.text.downcase.then do
          if it.end_with?("@#{@username.downcase}")
            it.match(/^(.*)@#{@username.downcase}$/).match(1)
          else
            it
          end
        end

        case text
        when '/start' then start_message message, user
        when '/help' then help_message message, user
        when '/stop' then stop message, user

        when '/set_group', LABELS[:my_group].downcase then configure_group message, user
        when ->(t) { user.state.start_with?('select_department') && user.departments.map(&:downcase).include?(t) }
          select_department message, user
        when ->(t) { user.groups.keys.map(&:downcase).include?(t) }
          select_group message, user

        when '/week', LABELS[:week].downcase then send_week_schedule message, user
        when '/tomorrow', LABELS[:tomorrow].downcase then send_tomorrow_schedule message, user
        when '/left', LABELS[:left].downcase then send_left_schedule message, user

        when LABELS[:quick_schedule].downcase
          ask_for_quick_schedule_type message, user
        when '/quick_schedule', LABELS[:other_group].downcase
          configure_group message, user, quick: true
        when '/teacher_schedule', LABELS[:teacher].downcase
          ask_for_teacher message, user
        when ->(t) { user.state == :teacher && t == 'отмена' }
          cancel_action message, user
        when ->(t) { user.state == :teacher && validate_teacher_name(t) }
          send_teacher_schedule message, user
        when ->(_) { user.state == :teacher }
          reask_for_teacher message, user, text

        when LABELS[:settings].downcase
          send_settings_menu message, user
        when '/configure_daily_sending', 'ежедневная рассылка'
          configure_daily_sending message, user
        when /^\d{1,2}:\d{2}$/
          if begin Time.parse message.text
          rescue StandardError then false
          end
            set_daily_sending message, user
          else
            bot.api.send_message(chat_id: message.chat.id, text: 'Неправильный формат времени, попробуйте ещё раз')
          end
        when '/daily_sending_off', 'отключить' then disable_daily_sending message, user
        when '/pair_sending_on', LABELS[:pair_sending_on].downcase then enable_pair_sending message, user
        when '/pair_sending_off', LABELS[:pair_sending_off].downcase then disable_pair_sending message, user
        when '/cancel', 'отмена' then cancel_action message, user
        when %r{^/debug\s+\w+$} then debug_command message, user
        end
      rescue StandardError => e
        log_error message, e
        bot.api.send_message(
          chat_id: message.chat.id,
          text: 'Произошла ошибка. Попробуйте позже.',
          reply_markup: default_reply_markup(user.id)
        )
      end
    end

    def log_error(message, error)
      msgs = ["Unhandled error in `#handle_text_message`: #{error.detailed_message}",
              "Message from #{message.from.full_name} @#{message.from.username} ##{message.from.id}"]
      backtrace = error.backtrace.join "\n"
      msgs.each { logger.error it }
      logger.debug "Backtrace:\n#{backtrace}"
      report("`#{msgs.join("\n")}`", backtrace: backtrace, log: 20)
    end

    def default_reply_markup(id)
      id.to_s.to_i.positive? ? DEFAULT_REPLY_MARKUP : { remove_keyboard: true }.to_json
    end
  end
end
