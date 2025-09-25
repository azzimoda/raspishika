# frozen_string_literal: true

require 'concurrent'
require 'rufus-scheduler'
require 'telegram/bot'

require_relative 'utils'
require_relative 'config'
require_relative 'logger'
require_relative 'parser'
require_relative 'dev_bot'
require_relative 'database'
require_relative 'session'

require_relative 'main_bot/callback_queries'
require_relative 'main_bot/general_commands'
require_relative 'main_bot/config_commands'
require_relative 'main_bot/schedule_commands'
require_relative 'main_bot/sending'

module Raspishika
  class Bot
    GlobalLogger.define_named_logger self

    TOKEN = Config[:bot][:token].freeze
    THEAD_POOL_SIZE = Config[:bot][:thread_pool_size].freeze
    MAX_RETRIES = Config[:bot][:max_retries].freeze
    SKIP_MESSAGE_TIME = Config[:bot][:skip_message_time].freeze * 60

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
      keyboard: DEFAULT_KEYBOARD, resize_keyboard: true, one_time_keyboard: false
    }.to_json.freeze
    MY_COMMANDS = [
      { command: 'left', description: 'Оставшиеся пары' },
      { command: 'tomorrow', description: 'Расписание на завтра' },
      { command: 'week', description: 'Расписание на неделю' },

      { command: 'quick', description: 'Расписание другой группы' },
      { command: 'teacher', description: 'Расписание преподавателя' },

      { command: 'daily_sending', description: 'Настроить ежедневную рассылку' },
      { command: 'daily_sending_off', description: 'Выкл. ежедневную рассылку' },

      { command: 'pair_sending_on', description: 'Вкл. уведомления перед парами' },
      { command: 'pair_sending_off', description: 'Выкл. уведомления перед парами' },

      { command: 'set_group', description: 'Изменить группу' },

      { command: 'cancel', description: 'Отменить действие' },
      { command: 'stop', description: 'Остановить бота и удалить данные о себе' },
      { command: 'help', description: 'Помощь' },
      { command: 'start', description: 'Запуск бота' }
    ].freeze

    def initialize
      @scheduler = Rufus::Scheduler.new
      @parser = ScheduleParser.new
      @thread_pool = Concurrent::FixedThreadPool.new THEAD_POOL_SIZE
      @retries = 0

      @token = TOKEN
      @run = true
      @dev_bot = DevBot.new main_bot: self
      @username = nil
    end
    attr_accessor :bot, :parser, :username

    def run
      logger.info 'Starting bot...'
      Telegram::Bot::Client.run(@token) do |bot|
        @bot = bot
        prepare_before_listen
        run_listener
      end
    rescue Interrupt then logger.warn 'Keyboard interruption'
    rescue StandardError => e then log_fatal e
    ensure shutdown
    end

    private

    def prepare_before_listen
      bot.api.set_my_commands(commands: MY_COMMANDS)
      @username = bot.api.get_me.username
      logger.debug "Bot's username: #{@username}"

      @dev_bot_thread = Thread.new(@dev_bot, &:run)

      if Config[:parser][:browser][:threaded]
        @parser.initialize_browser_thread
        sleep 0.1 until @parser.ready?
      end

      schedule_pair_sending
      schedule_db_backup
      @sending_thread = Thread.new(self, &:daily_sending_loop)
    end

    # Schedules a daily database backup at midnight using a cron job.
    def schedule_db_backup
      @scheduler.cron('0 0 * * *') { Raspishika.backup_database if @run }
      logger.info 'Database backup scheduled'
    end

    def run_listener
      logger.info 'Starting bot listener...'
      bot.listen { |message| handle_message message }
    rescue StandardError => e
      log_error nil, e, place: '#run_listener'
      logger.error "Retrying in 10 seconds... (#{@retries + 1}/#{MAX_RETRIES})"

      if (@retries += 1) < MAX_RETRIES
        sleep 10
        retry
      end
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

    def report(...)
      @dev_bot.report(...)
    end

    def handle_message(message)
      case message
      when Telegram::Bot::Types::CallbackQuery then handle_callback_query message
      when Telegram::Bot::Types::Message then handle_text_message message
      else logger.debug "Unhandled message type: #{message.class}"
      end
    end

    def handle_text_message(message)
      return if Time.at(message.date) < Time.now - SKIP_MESSAGE_TIME # Skip messages sent too long ago.
      return unless message.text

      short_text = message.text.size > 32 ? "#{message.text[0...32]}…" : message.text
      tg_chat = message.chat
      from = message.from
      if tg_chat.type == 'private'
        logger.info "[#{tg_chat.id}] @#{from.username} #{from.full_name} => #{short_text.inspect}"
      else
        logger.info("[#{tg_chat.id} @#{tg_chat.username} #{tg_chat.title}]" \
                     " @#{from.username} #{from.full_name} => #{short_text.inspect}")
      end

      chat = Chat.find_by tg_id: tg_chat.id
      chat ||= handle_new_chat message
      chat.update username: bot.api.get_chat(chat_id: chat.tg_id).username
      session = Session[chat]
      text = message.text.downcase.sub(/@#{@username.downcase}/, '')
      return if handle_command_message message, text, chat, session

      handle_button_message message, text, chat, session
    end

    def handle_new_chat(message)
      tg_chat = message.chat
      chat = Chat.create tg_id: tg_chat.id, username: tg_chat.username
      if chat.persisted?
        report_new_chat message
        return chat
      end

      logger.warn 'Failed to create a chat'
      logger.warn 'Trying to update username of already registered chat with the same username...'
      chat0 = Chat.find_by username: tg_chat.username
      if chat0 && chat0.username != (new_username = bot.api.get_chat(chat_id: chat0.tg_id).username)
        logger.warn 'Old chat have changed its username, the new chat have taken it. Updating the username...'
        chat0.update username: new_username

        chat = Chat.create! tg_id: tg_chat.id, username: tg_chat.username
        if chat.persisted?
          report_new_chat message
          return chat
        end
        logger.error 'Failed to create chat after updating username'
      end

      msg = "Failed to creade chat record for chat @#{tg_chat.username} ##{tg_chat.id}"
      report msg, log: 20
      logger.error msg
      send_message(chat_id: tg_chat.id, text: 'Произошла ошибка, обратитесь к разработчику: @MazzzaRellla')
      nil
    end

    def handle_command_message(message, text, chat, session)
      case text
      when '/start' then handle_command(message, chat, text, ok_stats: false) { start_message message, chat, session }
      when '/help' then handle_command(message, chat, text) { help_message message, chat, session }
      when '/stop' then handle_command(message, chat, text, ok_stats: false) { stop message, chat, session }

      when '/week' then handle_command(message, chat, text) { send_week_schedule message, chat, session }
      when '/tomorrow' then handle_command(message, chat, text) { send_tomorrow_schedule message, chat, session }
      when '/left' then handle_command(message, chat, text) { send_left_schedule message, chat, session }

      when '/set_group'
        handle_command(message, chat, text, ok_stats: false) { configure_group message, chat, session }
      when '/daily_sending'
        handle_command(message, chat, text, ok_stats: false) { configure_daily_sending message, chat, session }
      when '/daily_sending_off'
        handle_command(message, chat, text) { disable_daily_sending message, chat, session }
      when '/pair_sending_on' then handle_command(message, chat, text) { enable_pair_sending message, chat, session }
      when '/pair_sending_off' then handle_command(message, chat, text) { disable_pair_sending message, chat, session }
      when '/cancel' then handle_command(message, chat, '/cancel') { cancel_action message, chat, session }
      end
    end

    def handle_button_message(message, text, chat, session)
      case text
      when 'отмена' then handle_command(message, chat, '/cancel') { cancel_action message, chat, session }

      when ->(t) { session.default? && t == LABELS[:week].downcase }
        handle_command(message, chat, '/week') { send_week_schedule message, chat, session }
      when ->(t) { session.default? && t == LABELS[:tomorrow].downcase }
        handle_command(message, chat, '/tomorrow') { send_tomorrow_schedule message, chat, session }
      when ->(t) { session.default? && t == LABELS[:left].downcase }
        handle_command(message, chat, '/left') { send_left_schedule message, chat, session }

      when ->(t) { session.selecting_department? && session.departments.map(&:downcase).include?(t) }
        handle_command(message, chat, session.selecting_quick? ? '/quick' : '/set_group', ok_stats: false) do
          select_department message, chat, session
        end
      when ->(_) { session.selecting_department? }
        handle_command(message, chat, session.selecting_quick? ? '/quick' : '/set_group', ok_stats: false) do
          send_message(chat_id: message.chat.id, text: 'Неверное название отделения, попробуй ещё раз')
        end

      when ->(t) { session.selecting_group? && session.groups.keys.map(&:downcase).include?(t) }
        handle_command(message, chat, session.selecting_quick? ? '/quick' : '/set_group') do
          select_group message, chat, session
        end
      when ->(_) { session.selecting_group? }
        handle_command(message, chat, session.selecting_quick? ? '/quick' : '/set_group') do
          send_message(chat_id: message.chat.id, text: 'Неверное название группы, попробуй ещё раз')
        end

      when ->(t) { session.default? && t == LABELS[:quick_schedule].downcase }
        handle_command(message, chat, '/quick', ok_stats: false) do
          ask_for_quick_schedule_type message, chat, session
        end

      when ->(t) { session.quick_schedule? && t == LABELS[:other_group].downcase || t == '/quick' }
        handle_command(message, chat, '/quick', ok_stats: false) do
          configure_group message, chat, session, quick: true
        end
      when ->(t) { session.quick_schedule? && t == LABELS[:teacher].downcase || t == '/teacher' }
        handle_command(message, chat, '/teacher', ok_stats: false) { ask_for_teacher message, chat, session }

      when ->(_) { session.selecting_teacher? }
        if validate_teacher_name text
          handle_command(message, chat, '/teacher') { send_teacher_schedule message, chat, session }
        else
          handle_command(message, chat, '/teacher', ok_stats: false) do
            reask_for_teacher message, chat, session, text
          end
        end

      when ->(t) { session.default? && t == LABELS[:settings].downcase }
        handle_command(message, chat, '/settings', ok_stats: false) { send_settings_menu message, chat, session }
      when ->(t) { session.settings? && t == LABELS[:my_group].downcase }
        handle_command(message, chat, '/set_group', ok_stats: false) { configure_group message, chat, session }
      when ->(t) { session.settings? && t == LABELS[:daily_sending].downcase }
        handle_command(message, chat, '/daily_sending', ok_stats: false) do
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
          handle_command(message, chat, '/daily_sending', ok_stats: false) do
            send_message(chat_id: message.chat.id, text: 'Неправильный формат времени, попробуйте ещё раз')
          end
        end
      end
    end

    def report_new_chat(message)
      chat = message.chat
      from = message.from
      chat_id = chat.id
      username = (chat.type == 'private' ? from : chat).username&.escape_markdown
      title = (chat.type == 'private' ? from.full_name : chat.title).escape_markdown
      msg = "New #{chat.type} chat: [#{chat_id}] @#{username} #{title}"
      report msg
      report "`/chat #{chat_id}`", markdown: true
      logger.debug msg
    end

    def handle_command(message, chat, command_name, ok_stats: true)
      # Catch possible fail from methods `send_week_schedule` and `send_teacher_schedule`.
      failed = catch :fail do
        yield
        chat.log_command_usage(command_name, true, Time.now - Time.at(message.date)) if ok_stats
        false
      end

      chat.log_command_usage(command_name, false, Time.now - Time.at(message.date)) if failed
    rescue Telegram::Bot::Exceptions::ResponseError => e
      handle_telegram_api_error e, message
    rescue StandardError => e
      log_error chat, e, place: "#handle_command(command_name=#{command_name})"
      chat.log_command_usage(command_name, false, Time.now - Time.at(message.date))
      send_message(chat_id: message.chat.id, text: 'Произошла ошибка, попробуйте позже.', reply_markup: :default)
    end

    def handle_telegram_api_error(err, message)
      case err.error_code
      when 403 # Forbidden: bot was blocked by the user / kicked from the group chat
        msg = "Bot was blocked in #{message.chat.type} chat" \
              " ##{message.chat.id} @#{message.chat.username&.escape_markdown} #{message.chat.title&.escape_markdown}"
        report msg, markdown: true
        logger.warn msg
      when 429 # Too Many Requests
        retry_after = begin err.response['retry-after'].to_i + 10
        rescue StandardError then 10
        end
        logger.warn "Rate limited! Sleeping for #{retry_after} seconds..."
        sleep retry_after
      else
        log_error nil, err, place: '#handle_telegram_api_error'
        sleep 10
      end
    end

    def log_error(chat, error, place: nil)
      msgs = ["Unhandled error#{" in #{place}" if place}: #{error.detailed_message}"]
      msgs << "Message from chat @#{chat.username} ##{chat.tg_id}" if chat
      report(msgs.join("\n"), backtrace: error.backtrace.join("\n"), log: 20, code: true)
      msgs.each { logger.error it }
      logger.error error.backtrace.join("\n\t")
    end

    def log_fatal(err)
      puts
      'Unhandled error in the main method (#run):'.tap do |msg|
        report msg, backtrace: err.backtrace.join("\n"), log: 20, code: true
        logger.fatal msg
        logger.fatal err.detailed_message
        logger.fatal err.backtrace.join "\n\t"
      end
    end

    def send_photo(*args, **kwargs)
      photo_sending_retries = 0
      begin
        bot.api.send_photo(*args, **kwargs)
      rescue Net::ReadTimeout, Net::OpenTimeout, Faraday::ConnectionFailed, Faraday::TimeoutError => e
        logger.error "Failed to send photo to ##{kwargs[:chat_id]}: #{e.detailed_message}"
        if (photo_sending_retries += 1) < 3
          logger.info "Retrying... #{photo_sending_retries}/3"
          retry
        end
        send_message(chat_id: kwargs[:chat_id], text: 'Произошла ошибка, попробуйте позже.', reply_markup: :default)
      end
    end

    def send_message(**kwargs)
      kwargs[:reply_markup] = default_reply_markup kwargs[:chat_id] if kwargs[:reply_markup] == :default
      bot.api.send_message(**kwargs)
    end

    def default_reply_markup(id)
      id.to_s.to_i.positive? ? DEFAULT_REPLY_MARKUP : { remove_keyboard: true }.to_json
    end
  end
end
