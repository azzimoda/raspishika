# frozen_string_literal: true

require 'rufus-scheduler'
require 'telegram/bot'

require_relative 'config'
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
    TOKEN = Config[:bot][:token]
    THEAD_POOL_SIZE = Config[:bot][:thread_pool_size]
    MAX_RETRIES = Config[:bot][:max_retiries]

    LABELS = {
      left: 'Оставшиеся пары',
      tomorrow: 'Завтра',
      week: 'Неделя',

      quick_schedule: 'Быстрое расписание',
      settings: 'Настройки',

      other_group: 'Другая группа',
      teacher: 'Преподаватель',

      my_group: 'Моя группа',
      daily_sending: 'Ежедневная рассылка',
      disable: 'Отключить',
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
      Telegram::Bot::Client.run(@token) do |bot|
        @bot = bot

        prepare_before_listen

        report 'Bot started.'

        run_listener
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

    def prepare_before_listen
      bot.api.set_my_commands(commands: MY_COMMANDS)
      @username = bot.api.get_me.username
      logger.debug "Bot's username: #{@username}"

      @dev_bot_thread = Thread.new(@dev_bot, &:run)

      @users_saving_loop = Thread.new(self, &:users_save_loop)

      @parser.initialize_browser_thread
      sleep 0.1 until @parser.ready?

      schedule_pair_sending

      @sending_thread = Thread.new(self, &:daily_sending_loop)
    end

    def run_listener
      logger.info 'Starting bot listener...'
      bot.listen { |message| handle_message message }
    rescue StandardError => e
      "Unhandled error in `bot.listen`: #{e.detailed_message}".tap do |msg|
        report(msg, backtrace: e.backtrace.join("\n"), log: 20, code: true)
        logger.error msg
      end
      logger.error "Backtrace: #{e.backtrace.join("\n\t")}"
      logger.error "Retrying in 10 seconds... (#{@retries + 1}/#{MAX_RETRIES})"

      sleep 10
      @retries += 1
      retry if @retries < MAX_RETRIES
      'Reached maximum retries! Stopping bot...'.tap do |msg|
        report "FATAL ERROR: #{msg}", log: 20, code: true
        logger.fatal msg
      end
    end

    def shutdown
      report 'Bot stopped.'
      @run = false

      @users_saving_loop&.join
      User.save_all

      @dev_bot_thread&.kill
      @sending_thread&.join
      @parser.stop_browser_thread

      @thread_pool.shutdown
      @thread_pool.wait_for_termination 60
      @thread_pool.kill if @thread_pool.running?
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

      sending_thread_pool = Concurrent::FixedThreadPool.new(20)

      while @run
        current_time = Time.now

        users_to_send = User.users.values.select do
          it.daily_sending && Time.parse(it.daily_sending).between?(last_sending_time, current_time)
        end

        futures = users_to_send.map do |user|
          Concurrent::Future.execute(executor: sending_thread_pool) do
            start_time = Time.now
            send_week_schedule(nil, user)
            logger.debug "Daily schedule sent to #{user.id} (#{user.full_name})"
            user.push_daily_sending_report(conf_time: it.daily_sending, process_time: Time.now - start_time, ok: true)
          rescue StandardError => e
            user.push_daily_sending_report(
              conf_time: it.daily_sending, process_time: Time.now - start_time, ok: false
            )
            msg = "Error while sending daily schedule: #{e.detailed_message}"
            backtrace = e.backtrace.join("\n")
            report(msg, backtrace: backtrace, code: true)
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

      sending_thread_pool.shutdown
      sending_thread_pool.wait_for_termination 60
      sending_thread_pool.kill if sending_thread_pool.running?
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
      return unless Cache[:bot][:debug_commands]

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

      sending_thread_pool = Concurrent::FixedThreadPool.new 20

      groups =
        if user
          logger.debug "Sending pair notification for #{time} to #{user.id} with group #{user.group_info}..."
          { [user.department_name, user.group_name] => [user] }
        else
          User.users.values.select(&:pair_sending).group_by { [it.department_name, it.group_name] }
        end
      logger.debug "Sending pair notification to #{groups.size} groups..."

      futures = groups.map do |(_dname, gname), users|
        Concurrent::Future.execute(executor: sending_thread_pool) do
          send_pair_notification_for_group(users, time)
        rescue StandardError => e
          logger.error "Failed to send pair notification for #{gname}: #{e.detailed_message}"
          logger.error e.backtrace.join("\n\t")
        end
      end
      futures.each(&:wait)

      sending_thread_pool.shutdown
      sending_thread_pool.wait_for_termination 60
      sending_thread_pool.kill if sending_thread_pool.running?
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

      # TODO: Add response time metric to command statistics.
      logger.debug "Message handled within #{Time.now - Time.at(message.date)} seconds"
    end

    def handle_text_message(message)
      return unless message.text

      short_text = message.text.size > 32 ? "#{message.text[0...32]}…" : message.text
      if message.chat.type == 'private'
        logger.debug("[#{message.chat.id}] @#{message.from.username} #{message.from.full_name} => #{short_text.inspect}")
      else
        logger.debug("[#{message.chat.id} @#{message.chat.username} #{message.chat.title}]" \
                     " @#{message.from.username} #{message.from.full_name} => #{short_text.inspect}")
      end

      user = User[message.chat.id]
      unless user.statistics[:start]
        user.statistics[:start] = Time.now
        msg =
          if message.chat.type == 'private'
            "New private chat: [#{message.chat.id}] @#{message.from.username} #{message.from.full_name}"
          else
            "New group chat: [#{message.chat.id}] @#{message.chat.username} #{message.chat.title}"
          end
        report msg
        logger.debug msg
      end

      text = message.text.downcase.then do
        if it.end_with?("@#{@username.downcase}")
          it.match(/^(.*)@#{@username.downcase}$/).match(1)
        else
          it
        end
      end

      case text
      when '/start'
        handle_command(message, user, text, ok_stats: false) { start_message message, user }
      when '/help'
        handle_command(message, user, text) { help_message message, user }
      when '/stop'
        handle_command(message, user, text, ok_stats: false) { stop message, user }

      when '/week'
        handle_command(message, user, text) { send_week_schedule message, user }
      when '/tomorrow'
        handle_command(message, user, text) { send_tomorrow_schedule message, user }
      when '/left'
        handle_command(message, user, text) { send_left_schedule message, user }

      when '/set_group'
        handle_command(message, user, text, ok_stats: false) { configure_group message, user }
      when '/configure_daily_sending'
        handle_command(message, user, text, ok_stats: false) { configure_daily_sending message, user }
      when '/daily_sending_off'
        handle_command(message, user, text) { disable_daily_sending message, user }
      when '/pair_sending_on'
        handle_command(message, user, text) { enable_pair_sending message, user }
      when '/pair_sending_off'
        handle_command(message, user, text) { disable_pair_sending message, user }
      when '/cancel', 'отмена'
        handle_command(message, user, '/cancel') { cancel_action message, user }

      when ->(t) { user.default? && t == LABELS[:week].downcase }
        handle_command(message, user, '/week') { send_week_schedule message, user }
      when ->(t) { user.default? && t == LABELS[:tomorrow].downcase }
        handle_command(message, user, '/tomorrow') { send_tomorrow_schedule message, user }
      when ->(t) { user.default? && t == LABELS[:left].downcase }
        handle_command(message, user, '/left') { send_left_schedule message, user }

      when ->(t) { user.selecting_department? && user.departments.map(&:downcase).include?(t) }
        handle_command(message, user, user.selecting_quick? ? '/quick_schedule' : '/set_group', ok_stats: false) do
          select_department message, user
        end
      when ->(_) { user.selecting_department? }
        handle_command(message, user, user.selecting_quick? ? '/quick_schedule' : '/set_group', ok_stats: false) do
          bot.api.send_message(chat_id: message.chat.id, text: 'Неверное название отделения, попробуй ещё раз')
        end

      when ->(t) { user.selecting_group? && user.groups.keys.map(&:downcase).include?(t) }
        handle_command(message, user, user.selecting_quick? ? '/quick_schedule' : '/set_group') do
          select_group message, user
        end
      when ->(_) { user.selecting_group? }
        handle_command(message, user, user.selecting_quick? ? '/quick_schedule' : '/set_group') do
          bot.api.send_message(chat_id: message.chat.id, text: 'Неверное название группы, попробуй ещё раз')
        end

      when ->(t) { user.default? && t == LABELS[:quick_schedule].downcase }
        handle_command(message, user, '/quick_schedule', ok_stats: false) { ask_for_quick_schedule_type message, user }

      when ->(t) { user.quick_schedule? && t == LABELS[:other_group].downcase || t == '/quick_schedule' }
        handle_command(message, user, '/quick_schedule', ok_stats: false) { configure_group message, user, quick: true }
      when ->(t) { user.quick_schedule? && t == LABELS[:teacher].downcase || t == '/teacher_schedule' }
        handle_command(message, user, '/teacher_schedule', ok_stats: false) { ask_for_teacher message, user }

      when ->(_) { user.selecting_teacher? }
        if validate_teacher_name text
          handle_command(message, user, '/teacher_schedule') { send_teacher_schedule message, user }
        else
          handle_command(message, user, '/teacher_schedule', ok_stats: false) { reask_for_teacher message, user, text }
        end

      when ->(t) { user.default? && t == LABELS[:settings].downcase }
        handle_command(message, user, '/settings', ok_stats: false) { send_settings_menu message, user }
      when ->(t) { user.settings? && t == LABELS[:my_group].downcase }
        handle_command(message, user, '/set_group', ok_stats: false) { configure_group message, user }
      when ->(t) { user.settings? && t == LABELS[:daily_sending].downcase }
        handle_command(message, user, '/configure_daily_sending', ok_stats: false) do
          configure_daily_sending message, user
        end
      when ->(t) { user.settings? && t == LABELS[:pair_sending_on].downcase }
        handle_command(message, user, '/pair_sending_on') { enable_pair_sending message, user }
      when ->(t) { user.settings? && t == LABELS[:pair_sending_off].downcase }
        handle_command(message, user, '/pair_sending_off') { disable_pair_sending message, user }

      when ->(t) { user.setting_daily_sending? && t == LABELS[:disable].downcase }
        handle_command(message, user, '/daily_sending_off') { disable_daily_sending message, user }
      when ->(t) { user.setting_daily_sending? && t =~ /^\d{1,2}:\d{2}$/ }
        if begin Time.parse message.text
        rescue StandardError then false
        end
          handle_command(message, user, '/set_daily_sending') { set_daily_sending message, user }
        else
          handle_command(message, user, '/configure_daily_sending', ok_stats: false) do
            bot.api.send_message(chat_id: message.chat.id, text: 'Неправильный формат времени, попробуйте ещё раз')
          end
        end
      when %r{^/debug\s+\w+$} then debug_command message, user
      end
    end

    def handle_command(message, user, command_name, ok_stats: true)
      if catch :fail do
        yield
        user.push_command_usage command: command_name, ok: true if ok_stats
        false
      end
        user.push_command_usage command: command_name, ok: false
      end
    rescue Telegram::Bot::Exceptions::ResponseError => e
      handle_telegram_api_error e, message
    rescue StandardError => e
      log_error message, e
      user.push_command_usage command: command_name, ok: false
      bot.api.send_message(
        chat_id: message.chat.id,
        text: 'Произошла ошибка, попробуйте позже.',
        reply_markup: default_reply_markup(user.id)
      )
    end

    def handle_telegram_api_error(err, message)
      case err.error_code
      when 403 # Forbidden: bot was blocked by the user / kicked from the group chat
        msg =
          "Bot was blocked in #{message.chat.type} ##{message.chat.id} @#{message.chat.username} #{message.chat.title}"
        report msg
        logger.warn msg
      when 429 # Too Many Requests
        retry_after = begin err.response['retry-after'].to_i + 10
        rescue StandardError then 10
        end
        logger.warn "Rate limited! Sleeping for #{retry_after} seconds..."
        sleep retry_after
      else
        report "Telegram API error: #{err.detailed_message}", backtrace: err.backtrace.join("\n"), log: 20, code: true
        logger.error "Unhandled Telegram API error: #{err.detailed_message}"
        logger.error err.backtrace.join("\n\t")
        sleep 10
      end
    end

    def log_error(message, error)
      msgs = ["Unhandled error in `#handle_text_message`: #{error.detailed_message}",
              "Message from #{message.from.full_name} @#{message.from.username} ##{message.from.id}"]
      report("`#{msgs.join("\n")}`", backtrace: error.backtrace.join("\n"), log: 20)
      msgs.each { logger.error it }
      logger.debug "Backtrace: #{error.backtrace.join("\n\t")}"
    end

    def send_photo(*args, **kwargs)
      photo_sending_retries = 0
      begin
        bot.api.send_photo(*args, **kwargs)
      rescue Net::OpenTimeout, Faraday::ConnectionFailed => e
        logger.error "Failed to send photo to ##{user.id}: #{e.detailed_message}"
        photo_sending_retries += 1
        retry if photo_sending_retries < 3
        bot.api.send_message(
          chat_id: message.chat.id,
          text: 'Произошла ошибка, попробуйте позже.',
          reply_markup: default_reply_markup(user.id)
        )
      end
    end

    def default_reply_markup(id)
      id.to_s.to_i.positive? ? DEFAULT_REPLY_MARKUP : { remove_keyboard: true }.to_json
    end
  end
end
