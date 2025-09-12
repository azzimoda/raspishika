# frozen_string_literal: true

require 'concurrent'
require 'rufus-scheduler'
require 'telegram/bot'

require_relative 'config'
require_relative 'logger'
require_relative 'parser'
require_relative 'dev_bot'
require_relative 'database'
require_relative 'session'

require_relative 'main_bot/debug_commands'
require_relative 'main_bot/general_commands'
require_relative 'main_bot/config_commands'
require_relative 'main_bot/schedule_commands'
require_relative 'main_bot/sending'

class Telegram::Bot::Types::User # rubocop:disable Style/ClassAndModuleChildren,Style/Documentation
  def full_name
    "#{first_name} #{last_name}".strip
  end
end

module Raspishika
  class Bot
    TOKEN = Config[:bot][:token]
    THEAD_POOL_SIZE = Config[:bot][:thread_pool_size]
    MAX_RETRIES = Config[:bot][:max_retries]

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

      ImageGenerator.logger = Cache.logger = @logger
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

    # Schedules a daily database backup at midnight using a cron job.
    def schedule_db_backup
      @scheduler.cron '0 0 * * *' do
        backup_database if @run
      end
    end

    private

    def prepare_before_listen
      bot.api.set_my_commands(commands: MY_COMMANDS)
      @username = bot.api.get_me.username
      logger.debug "Bot's username: #{@username}"

      @dev_bot_thread = Thread.new(@dev_bot, &:run)

      @parser.initialize_browser_thread
      sleep 0.1 until @parser.ready?

      schedule_pair_sending
      schedule_db_backup

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

      @dev_bot_thread&.kill
      @sending_thread&.join
      @parser.stop_browser_thread

      @thread_pool.shutdown
      @thread_pool.wait_for_termination 60
      @thread_pool.kill if @thread_pool.running?
    end

    def debug_command(message, user)
      return unless Cache[:bot][:debug_commands]

      debug_command_name = message.text.split(' ').last
      logger.info "Calling test #{debug_command_name}..."
      unless DebugCommands.respond_to? debug_command_name
        logger.warn "Test #{debug_command_name} not found"
        send_message(
          chat_id: message.chat.id,
          text: "Тест `#{debug_command_name}` не найден.\n\nДоступные тесты: #{DebugCommands.methods.join(', ')}",
          reply_markup: default_reply_markup(user.id)
        )
        return
      end

      DebugCommands.send(debug_command_name, bot: self, user: user, message: message)
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

      short_text = message.text.size > 32 ? "#{message.text[0...32]}…" : message.text
      if message.chat.type == 'private'
        logger.debug("[#{message.chat.id}] @#{message.from.username} #{message.from.full_name} => #{short_text.inspect}")
      else
        logger.debug("[#{message.chat.id} @#{message.chat.username} #{message.chat.title}]" \
                     " @#{message.from.username} #{message.from.full_name} => #{short_text.inspect}")
      end

      chat = Chat.find_by tg_id: message.chat.id
      unless chat
        chat = Chat.create! tg_id: message.chat.id, username: message.chat.username
        msg =
          if message.chat.type == 'private'
            "New private chat: [#{message.chat.id}] @#{message.from.username} #{message.from.full_name}"
          else
            "New group chat: [#{message.chat.id}] @#{message.chat.username} #{message.chat.title}"
          end
        report msg
        logger.debug msg
      end
      session = Session[chat]

      text = message.text.downcase.then do
        if it.end_with?("@#{@username.downcase}")
          it.match(/^(.*)@#{@username.downcase}$/).match(1)
        else
          it
        end
      end

      case text
      when '/start'
        handle_command(message, chat, text, ok_stats: false) { start_message message, chat, session }
      when '/help'
        handle_command(message, chat, text) { help_message message, chat, session }
      when '/stop'
        handle_command(message, chat, text, ok_stats: false) { stop message, chat, session }

      when '/week'
        handle_command(message, chat, text) { send_week_schedule message, chat, session }
      when '/tomorrow'
        handle_command(message, chat, text) { send_tomorrow_schedule message, chat, session }
      when '/left'
        handle_command(message, chat, text) { send_left_schedule message, chat, session }

      when '/set_group'
        handle_command(message, chat, text, ok_stats: false) { configure_group message, chat, session }
      when '/configure_daily_sending'
        handle_command(message, chat, text, ok_stats: false) { configure_daily_sending message, chat, session }
      when '/daily_sending_off'
        handle_command(message, chat, text) { disable_daily_sending message, chat, session }
      when '/pair_sending_on'
        handle_command(message, chat, text) { enable_pair_sending message, chat, session }
      when '/pair_sending_off'
        handle_command(message, chat, text) { disable_pair_sending message, chat, session }
      when '/cancel', 'отмена'
        handle_command(message, chat, '/cancel') { cancel_action message, chat, session }

      when ->(t) { session.default? && t == LABELS[:week].downcase }
        handle_command(message, chat, '/week') { send_week_schedule message, chat, session }
      when ->(t) { session.default? && t == LABELS[:tomorrow].downcase }
        handle_command(message, chat, '/tomorrow') { send_tomorrow_schedule message, chat, session }
      when ->(t) { session.default? && t == LABELS[:left].downcase }
        handle_command(message, chat, '/left') { send_left_schedule message, chat, session }

      when ->(t) { session.selecting_department? && session.departments.map(&:downcase).include?(t) }
        handle_command(message, chat, session.selecting_quick? ? '/quick_schedule' : '/set_group', ok_stats: false) do
          select_department message, chat, session
        end
      when ->(_) { session.selecting_department? }
        handle_command(message, chat, session.selecting_quick? ? '/quick_schedule' : '/set_group', ok_stats: false) do
          send_message(chat_id: message.chat.id, text: 'Неверное название отделения, попробуй ещё раз')
        end

      when ->(t) { session.selecting_group? && session.groups.keys.map(&:downcase).include?(t) }
        handle_command(message, chat, session.selecting_quick? ? '/quick_schedule' : '/set_group') do
          select_group message, chat, session
        end
      when ->(_) { session.selecting_group? }
        handle_command(message, chat, session.selecting_quick? ? '/quick_schedule' : '/set_group') do
          send_message(chat_id: message.chat.id, text: 'Неверное название группы, попробуй ещё раз')
        end

      when ->(t) { session.default? && t == LABELS[:quick_schedule].downcase }
        handle_command(message, chat, '/quick_schedule', ok_stats: false) do
          ask_for_quick_schedule_type message, chat, session
        end

      when ->(t) { session.quick_schedule? && t == LABELS[:other_group].downcase || t == '/quick_schedule' }
        handle_command(message, chat, '/quick_schedule', ok_stats: false) do
          configure_group message, chat, session, quick: true
        end
      when ->(t) { session.quick_schedule? && t == LABELS[:teacher].downcase || t == '/teacher_schedule' }
        handle_command(message, chat, '/teacher_schedule', ok_stats: false) { ask_for_teacher message, chat, session }

      when ->(_) { session.selecting_teacher? }
        if validate_teacher_name text
          handle_command(message, chat, '/teacher_schedule') { send_teacher_schedule message, chat, session }
        else
          handle_command(message, chat, '/teacher_schedule', ok_stats: false) do
            reask_for_teacher message, chat, session, text
          end
        end

      when ->(t) { session.default? && t == LABELS[:settings].downcase }
        handle_command(message, chat, '/settings', ok_stats: false) { send_settings_menu message, chat, session }
      when ->(t) { session.settings? && t == LABELS[:my_group].downcase }
        handle_command(message, chat, '/set_group', ok_stats: false) { configure_group message, chat, session }
      when ->(t) { session.settings? && t == LABELS[:daily_sending].downcase }
        handle_command(message, chat, '/configure_daily_sending', ok_stats: false) do
          configure_daily_sending message, chat, session
        end
      when ->(t) { session.settings? && t == LABELS[:pair_sending_on].downcase }
        handle_command(message, chat, '/pair_sending_on') { enable_pair_sending message, chat, session }
      when ->(t) { session.settings? && t == LABELS[:pair_sending_off].downcase }
        handle_command(message, chat, '/pair_sending_off') { disable_pair_sending message, chat, session }

      when ->(t) { session.setting_daily_sending? && t == LABELS[:disable].downcase }
        handle_command(message, chat, '/daily_sending_off') { disable_daily_sending message, chat, session }
      when ->(t) { session.setting_daily_sending? && t =~ /^\d{1,2}:\d{2}$/ }
        if begin Time.parse message.text
        rescue StandardError then false
        end
          handle_command(message, chat, '/set_daily_sending') { set_daily_sending message, chat, session }
        else
          handle_command(message, chat, '/configure_daily_sending', ok_stats: false) do
            send_message(chat_id: message.chat.id, text: 'Неправильный формат времени, попробуйте ещё раз')
          end
        end
      when %r{^/debug\s+\w+$} then debug_command message, chat
      end
    end

    def handle_command(message, chat, command_name, ok_stats: true)
      # Catch possible fail from methods `send_week_schedule` and `send_teacher_schedule`
      failed = catch :fail do
        yield
        chat.log_command_usage(command_name, true, Time.now - Time.at(message.date)) if ok_stats
        false
      end

      chat.log_command_usage(command_name, false, Time.now - Time.at(message.date)) if failed
    rescue Telegram::Bot::Exceptions::ResponseError => e
      handle_telegram_api_error e, message
    rescue StandardError => e
      log_error message, e
      chat.log_command_usage(command_name, false, Time.now - Time.at(message.date))
      send_message(
        chat_id: message.chat.id,
        text: 'Произошла ошибка, попробуйте позже.',
        reply_markup: default_reply_markup(chat.tg_id)
      )
    ensure
      logger.debug "Message handled within #{Time.now - Time.at(message.date)} seconds"
      logger.debug "Current chat's state: #{Session[chat].state}"
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
        logger.error "Failed to send photo to ##{chat.tg_id}: #{e.detailed_message}"
        photo_sending_retries += 1
        retry if photo_sending_retries < 3
        send_message(
          chat_id: message.chat.id,
          text: 'Произошла ошибка, попробуйте позже.',
          reply_markup: default_reply_markup(chat.tg_id)
        )
      end
    end

    def send_message(*args, **kwargs)
      bot.api.send_message(*args, **kwargs)
    end

    def default_reply_markup(id)
      id.to_s.to_i.positive? ? DEFAULT_REPLY_MARKUP : { remove_keyboard: true }.to_json
    end
  end
end
