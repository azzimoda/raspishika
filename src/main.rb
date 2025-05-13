require 'logger'
require 'telegram/bot'
require 'nokogiri'
require 'open-uri'
require 'uri'
require 'cgi'
require 'selenium-webdriver'
require 'timeout'

require './src/cache'
require './src/debug_commands'
require './src/parser'
require './src/schedule'
require './src/user'

if ENV['TELEGRAM_BOT_TOKEN'].nil?
  puts "Environment variable TELEGRAM_BOT_TOKEN is nil"
  quit
end

class RaspishikaBot
  DEFAULT_KEYBOARD = [
    ["Оставшиеся пары"],
    ["Сегодня/Завтра", "Неделя"],
    ["Выбрать другую группу", "Задать таймер"],
  ]
  if ENV["DEBUG_CM"]
    DEFAULT_KEYBOARD.push(
      ["/debug user_info", "/debug set_user_info", "/debug delete_user", "/debug clear_cache"]
    )
  end
  DEFAULT_KEYBOARD.freeze
  DEFAULT_REPLY_MARKUP = {
    keyboard: DEFAULT_KEYBOARD,
    resize_keyboard: true,
    one_time_keyboard: true,
  }.to_json.freeze

  def initialize
    @logger = Logger.new($stderr, level: Logger::DEBUG)
    $logger = @logger
    @parser = ScheduleParser.new(logger: @logger)
    @token = ENV['TELEGRAM_BOT_TOKEN']

    Cache.logger = @logger
    User.logger = @logger
    User.restore
  end
  attr_accessor :logger, :parser

  def bot
    @mutex.synchronize { @bot }
  end
  # TODO: Use this method instead of @user

  def run
    Telegram::Bot::Client.run(@token) do |bot|
      logger.info "Bot started"
      @bot = bot
      @bot.api.set_my_commands(
        commands: [
          {command: 'start', description: 'Запуск бота'},
          {command: 'help', description: 'Помощь'},
          {command: 'set_group', description: 'Выбрать группу'},
          {command: 'set_timer', description: 'Задать таймер'},
          {command: 'off_timer', description: 'Выключить таймер'},
          {command: 'cancel', description: 'Отменить действие'},
          {command: 'left', description: 'Оставшиеся пары'},
          {command: 'today_tomorrow', description: 'Расписание на сегодня и завтра'},
          {command: 'week', description: 'Расписание на неделю'},
        ]
      )

      @bot.listen do |message|
        handle_message message
      end
    end
  rescue Interrupt
    puts
    logger.warn "Keyboard interruption"
  ensure
    User.backup
  end

  private

  def handle_message message
    logger.debug "Received: #{message.text} from #{message.chat.id} (#{message.from.username})"
    begin
      user = User[message.chat.id]
      case message.text.downcase
      when '/start' then start_message message, user
      when '/help' then help_message message, user
      when '/set_group', 'выбрать другую группу' then configure_group message, user
      # TODO: Try to optimize the line length with DS.
      when ->(t) { user.state == :select_department && user.departments.map(&:downcase).include?(t) }
        select_department message, user
      when ->(t) { user.groups.keys.map(&:downcase).include?(t) }
        select_group message, user
      when '/week', 'неделя' then send_week_schedule message, user
      when '/today_tomorrow', 'сегодня/завтра' then send_tt_schedule message, user
      when '/left', 'оставшиеся пары' then send_left_schedule message, user
      when '/set_timer', 'задать таймер' then configure_timer message, user
      when '/cancel', 'отмена' then cancel_action message, user
      when %r(^/debug\s+\w+$) then debug_command message, user
      else
        @bot.api.send_message(
          chat_id: message.chat.id,
          text: "Я не знаю как ответить на это сообщение :(",
          reply_markup: DEFAULT_REPLY_MARKUP
        )
      end
    rescue => e
      logger.error "Error: #{e.message}\n#{e.backtrace.join("\n")}"
      @bot.api.send_message(
        chat_id: message.chat.id,
        text: "Произошла ошибка. Попробуйте позже.",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
      # TODO: report_error_to_developer(e)
    end
  end

  def start_message(message, user)
    @bot.api.send_message(
      chat_id: message.chat.id,
      text:
        "Привет! Используй /set_group чтобы задать группу для регулярного расписания " \
        "и кнопки ниже для других действий.",
      reply_markup: DEFAULT_REPLY_MARKUP
    )
  end

  def help_message(message, user)
    @bot.api.send_message(
      chat_id: message.chat.id,
      text: "Помощи не будет(",
      reply_markup: DEFAULT_REPLY_MARKUP
    )
  end

  def configure_group(message, user)
    # TODO: Add loading message like in `#select_group`.
    departments = Cache.fetch(:departments) { @parser.fetch_departments }
    if departments.any?
      user.departments = departments.keys
      user.state = :select_department

      keyboard = [["Отмена"]] + departments.keys.each_slice(2).to_a
      @bot.api.send_message(
        chat_id: message.chat.id,
        text: "Выбери отделение",
        reply_markup: {
          keyboard: keyboard,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    else
      @bot.api.send_message(
        chat_id: message.chat.id,
        text: "Не удалось загрузить отделения",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
    end
  end

  def select_department(message, user)
    # TODO: Add loading message like in `#select_group`.
    departments = Cache.fetch(:departments) { @parser.fetch_departments }
    # Additional check
    if departments.key? message.text
      groups = Cache.fetch(:"groups_#{message.text.downcase}") do
        @parser.fetch_groups departments[message.text]
      end
      if groups.any?
        user.department_url = departments[message.text]
        user.z = message.text.downcase == 'заочное обучение'
        user.departments = []
        user.groups = groups
        user.state = :select_group

        keyboard = [["Отмена"]] + groups.keys.each_slice(2).to_a
        @bot.api.send_message(
          chat_id: message.chat.id,
          text: "Выбери группу",
          reply_markup: {
            keyboard: keyboard,
            resize_keyboard: true,
            one_time_keyboard: true
          }.to_json
        )
      else
        @bot.api.send_message(
          chat_id: message.chat.id,
          text: "Не удалось загрузить группы для этого отделения",
          reply_markup: DEFAULT_REPLY_MARKUP
        )
      end
    else
      user.department_url = nil
      user.departments = []
      user.groups = {}
      user.state = :default
      logger.warn "Cached departments differ from fetched"
      @bot.api.send_message(
        chat_id: message.chat.id,
        text: "Не удалось загрузить отделение",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
    end
  end

  def select_group(message, user)
    sent_message = @bot.api.send_message(
      chat_id: message.chat.id,
      text: "Сверяю данные...",
      reply_markup: { remove_keyboard: true }.to_json
    )

    # groups = Cache.fetch(:"groups_#{group}") { @parser.fetch_groups user.department_url }
    if (group_info = user.groups[message.text])
      user.department = group_info[:sid]
      user.group = group_info[:gr]
      user.group_name = message.text

      schedule = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
        @parser.fetch_schedule group_info.merge({group: message.text})
      end
      text = if schedule then "Теперь ты в группе #{message.text}"
      else "Не удалось получить данные для этой группы. Попробуйте позже."
      end

      bot.api.delete_message(chat_id: message.chat.id, message_id: sent_message.message_id)
      @bot.api.send_message(
        chat_id: message.chat.id,
        text: text,
        reply_markup: DEFAULT_REPLY_MARKUP
      )
    else
      user.department = nil
      user.group = nil

      @bot.api.delete_message(chat_id: message.chat.id, message_id: sent_message.message_id)
      @bot.api.send_message(
        chat_id: message.chat.id,
        text: "Группа #{message.text} не найдена. Доступные группы:\n#{user.groups.keys.join(" , ")}",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
    end

    user.groups = {}
    user.state = :default
  end

  def send_week_schedule(message, user)
    # TODO: Add loading message like in `#select_group`.
    unless user.department && user.group
      bot.api.send_message(chat_id: message.chat.id, text: "Группа не выбрана")
      return configure_group(message, user)
    end

    _ = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
      @parser.fetch_schedule user.group_info.merge({group: user.group_name})
    end
    @bot.api.send_photo(
      chat_id: message.chat.id,
      photo: Faraday::UploadIO.new(".cache/#{user.department}_#{user.group}.png", 'image/png'),
      reply_markup: DEFAULT_REPLY_MARKUP
    )
  end

  def send_tt_schedule(message, user)
    # TODO: Add loading message like in `#select_group`.
    unless user.department && user.group
      bot.api.send_message(chat_id: message.chat.id, text: "Группа не выбрана")
      return configure_group(message, user)
    end

    schedule = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
      @parser.fetch_schedule user.group_info.merge({group: user.group_name})
    end
    text = Schedule.from_raw(schedule).days(0, 2).format
    @bot.api.send_message(chat_id: message.chat.id, text:, reply_markup: DEFAULT_REPLY_MARKUP)
  end

  def send_left_schedule(message, user)
    # TODO: Add loading message like in `#select_group`.
    unless user.department && user.group
      bot.api.send_message(chat_id: message.chat.id, text: "Группа не выбрана")
      return configure_group(message, user)
    end

    schedule = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
      # TODO: Add group_name to user.group_info EVERYWHERE.
      @parser.fetch_schedule user.group_info.merge({group: user.group_name})
    end
    text = Schedule.from_raw(schedule).left.format
    @bot.api.send_message(
      chat_id: message.chat.id,
      text: text,
      reply_markup: DEFAULT_REPLY_MARKUP
    )
  end

  def configure_timer(message, user)
    @bot.api.send_message(
      chat_id: message.chat.id,
      text: "Таймер не реализован",
      reply_markup: DEFAULT_REPLY_MARKUP
    )
    # TODO: Implement the timer
    # User can have 2 timers: once per day and before each pair. Both can be on/off separately.
  end

  def debug_command(message, user)
    return unless ENV['DEBUG_CM']

    debug_command_name = message.text.split(' ').last
    logger.info "Calling test #{debug_command_name}..."
    unless DebugCommands.respond_to? debug_command_name
      logger.warn "Test #{debug_command_name} not found"
      @bot.api.send_message(
        chat_id: message.chat.id,
        text: "Тест `#{debug_command_name}` не найден.\n\nДоступные тесты: #{DebugCommands.methods.join(', ')}",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
      return
    end

    DebugCommands.send(debug_command_name, bot: self, user: user, message: message)
  end

  def cancel_action (message, user)
    case user.state
    when :default
      @bot.api.send_message(chat_id: message.chat.id, text: "Нечего отменять")
    else # :select_department, :select_group, :select_timer
      user.state = :default
      @bot.api.send_message(
        chat_id: message.chat.id,
        text: "Действие отменено",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
    end
  end
end

RaspishikaBot.new.run
