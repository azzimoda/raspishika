require 'telegram/bot'
require 'date'

require_relative 'cache'
require_relative 'debug_commands'
require_relative 'parser'
require_relative 'schedule'
require_relative 'user'
require_relative 'dev_bot'
require_relative 'logger'

if (message = ENV['NOTIFY'])
  require_relative 'notification'
  User.logger = Logger.new($stdout, Logger::DEBUG)
  User.restore
  notify message
  exit
end

if ENV['TELEGRAM_BOT_TOKEN'].nil?
  puts "FATAL: Environment variable TELEGRAM_BOT_TOKEN is nil"
  quit
end

HOUR = 60 * 60

class RaspishikaBot
  DEFAULT_KEYBOARD = [
    ["Оставшиеся пары"],
    ["Завтра", "Неделя"],
    ["Выбрать другую группу", "Настроить рассылку"],
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

  HELP_MESSAGE = <<~MARKDOWN
  Доступные команды:

  - /start — Запустить бота.
  - /help — Показать это сообщение помощи.
  - /set_group — Выбрать или изменить группу для получения расписания. Следуйте инструкциям: сначала выберите отделение, затем группу.
  - /week — Получить расписание на неделю.
  - /tomorrow — Получить расписание на завтра.
  - /left — Получить информацию об оставшихся парах на сегодня.
  - /config_sending — Настроить рассылку.
  - /cancel — Отменить текущее действие.

  Для использования команд /week, /tomorrow, /today_tomorrow, /left необходимо сначала задать группу с помощью /set_group.

  Командой /config_sending можно настроить ежедневную рассылку расписания на неделю. Опция "рассылка перед парами" находится в разработке.

  Вы также можете использовать кнопки клавиатуры для быстрого доступа к основным функциям.
  MARKDOWN

  def initialize
    @logger = MyLogger.new # Logger.new($stderr, level: Logger::DEBUG)
    @parser = ScheduleParser.new(logger: @logger)
    @token = ENV['TELEGRAM_BOT_TOKEN']
    @run = true
    @dev_bot = RaspishikaDevBot.new logger: @logger

    ImageGenerator.logger = Cache.logger = User.logger = @logger
    User.restore
  end
  attr_accessor :bot, :logger, :parser

  def run
    @dev_bot_thread = Thread.new(@dev_bot, &:run)

    logger.info "Starting bot..."
    @parser.initialize_browser_thread

    Telegram::Bot::Client.run(@token) do |bot|
      @bot = bot
      bot.api.set_my_commands(
        commands: [
          {command: 'start', description: 'Запуск бота'},
          {command: 'help', description: 'Помощь'},
          {command: 'set_group', description: 'Выбрать группу'},
          {command: 'configure_sending', description: 'Насторить рассылку'},
          {command: 'cancel', description: 'Отменить действие'},
          {command: 'left', description: 'Оставшиеся пары'},
          {command: 'tomorrow', description: 'Расписание на завтра'},
          {command: 'week', description: 'Расписание на неделю'},
        ]
      )

      sleep 1 until @parser.ready?

      report "Bot started."

      @sending_thread = Thread.new(self, &:sending_loop)

      begin
        logger.info "Starting bot listen loop..."
        bot.listen { |message| handle_message message }
      rescue Telegram::Bot::Exceptions::ResponseError => e
        msg = "Telegram API error: #{e.detailed_message}; retrying..."
        logger.error msg
        report(msg, backtrace: e.backtrace.join("\n"))
        sleep 5
        retry
      rescue => e
        msg = "Unhandled error in `bot.listen`: #{e.detailed_message}; retrying..."
        logger.error msg
        report(msg, backtrace: e.backtrace.join("\n"))
        sleep 5
        retry
      end
    end
  rescue Interrupt
    puts
    logger.warn "Keyboard interruption"
  ensure
    report "Bot stopped."
    @run = false
    User.backup
    @dev_bot_thread.kill
    @sending_thread.join
    @parser.stop_browser_thread
  end

  def sending_loop
    logger.info "Starting sending loop..."
    last_sending_time = Time.now - 10*60

    while @run
      current_time = Time.now

      users_to_send = User.users.values.select do
        it.daily_sending && Time.parse(it.daily_sending).between?(last_sending_time, current_time)
      end

      users_to_send.each do
        send_week_schedule(nil, it)
      rescue => e
        msg = "Error while sending daily schedule: #{e.detailed_message}"
        backtrace = e.backtrace.join("\n")
        logger.error msg
        logger.debug backtrace
        report(msg, backtrace:)
      end
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

  private

  def report(*args, **kwargs)
    @dev_bot.report(*args, **kwargs)
  end

  def handle_message message
    logger.debug(
      "Received: #{message.text} from #{message.chat.id}" \
      " (@#{message.from.username}, #{message.from.first_name} #{message.from.last_name})"
    )
    begin
      user = User[message.chat.id]
      if message.text.downcase != '/start' && user.statistics[:start].nil?
        user.statistics[:start] = Time.now
        msg = "New user: #{message.chat.id}" \
          " (@#{message.from.username}, #{message.from.first_name} #{message.from.last_name})"
        logger.debug msg
        report msg
      end

      case message.text.downcase
      when '/start' then start_message message, user
      when '/help' then help_message message, user
      when '/set_group', 'выбрать другую группу' then configure_group message, user
      when ->(t) { user.state == :select_department && user.departments.map(&:downcase).include?(t) }
        select_department message, user
      when ->(t) { user.groups.keys.map(&:downcase).include?(t) }
        select_group message, user
      when '/week', 'неделя' then send_week_schedule message, user
      when '/tomorrow', 'завтра' then send_tomorrow_schedule message, user
      when '/left', 'оставшиеся пары' then send_left_schedule message, user
      when '/configure_sending', 'насторить рассылку' then configure_sending message, user
      when 'ежедневная рассылка' then configure_daily_sending message, user
      when %r(^\d{1,2}:\d{2}$)
        if (message.text =~ %r(^\d{1,2}:\d{2}$) && Time.parse(message.text) rescue false)
          set_daily_sending message, user
        else
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Неправильный формат времени, попробуйте ещё раз",
          )
        end
      when 'отключить' then disable_daily_sending message, user
      when 'вкл. рассылку перед парами' then enable_pair_sending message, user
      when 'выкл. рассылку перед парами' then disable_pair_sending message, user
      when '/cancel', 'отмена' then cancel_action message, user
      when %r(^/debug\s+\w+$) then debug_command message, user
      else
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Я не знаю как ответить на это сообщение :(",
        )
      end
    rescue => e
      msg =
        "Unhandled error in `#handle_message`: #{e.detailed_message}\n" \
        "\tFrom #{message.chat.id} (#{message.from.username}); message #{message.text.inspect}"
      logger.error msg
      logger.debug e.backtrace.join"\n"
      report(msg, backtrace: e.backtrace.join("\n"), log: nil)
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Произошла ошибка. Попробуйте позже.",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
    end
  end

  def start_message(message, user)
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Привет! Используй /set_group чтобы задать группу и кнопки ниже для других действий",
      reply_markup: DEFAULT_REPLY_MARKUP
    )

    unless user.statistics[:start]
      user.statistics[:start] = Time.now
      msg = "New user: #{message.chat.id}" \
        " (@#{message.from.username}, #{message.from.first_name} #{message.from.last_name})"
      logger.debug msg
      report msg
    end
  end

  def help_message(message, user)
    bot.api.send_message(
      chat_id: message.chat.id,
      text: HELP_MESSAGE,
      reply_markup: DEFAULT_REPLY_MARKUP
    )
  end

  def configure_group(message, user)
    departments = Cache.fetch(:departments, expires_in: HOUR) { parser.fetch_departments }
    if departments&.any?
      user.departments = departments.keys
      user.state = :select_department

      keyboard = [["Отмена"]] + departments.keys.each_slice(2).to_a
      bot.api.send_message(
        chat_id: user.id,
        text: "Выбери отделение",
        reply_markup: {
          keyboard: keyboard,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    else
      bot.api.send_message(
        chat_id: user.id,
        text: "Не удалось загрузить отделения",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
    end
  end

  def select_department(message, user)
    departments = Cache.fetch(:departments, expires_in: HOUR) { parser.fetch_departments }

    if departments&.key? message.text
      groups = Cache.fetch(:"groups_#{message.text.downcase}", expires_in: HOUR) do
        parser.fetch_groups departments[message.text]
      end
      if groups&.any?
        user.department_url = departments[message.text]
        user.department_name_temp = message.text
        user.groups = groups
        user.state = :select_group

        keyboard = [["Отмена"]] + groups.keys.each_slice(2).to_a
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Выбери группу",
          reply_markup: {
            keyboard: keyboard,
            resize_keyboard: true,
            one_time_keyboard: true
          }.to_json
        )
      else
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Не удалось загрузить группы для этого отделения",
          reply_markup: DEFAULT_REPLY_MARKUP
        )
      end
    else
      user.departments = []
      user.state = :default

      logger.warn "Cached departments differ from fetched"
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Не удалось загрузить отделение",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
      logger.warn "Reached code supposed to be unreachable!"
      msg = "User #{message.chat.id} (#{message.from.username}) tried to select department #{message.text} but it doesn't exist"
      logger.warn msg
      report msg
    end
  end

  def select_group(message, user)
    if (group_info = user.groups[message.text])
      user.department = group_info[:sid]
      user.department_name = user.department_name_temp
      user.group = group_info[:gr]
      user.group_name = message.text

      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Теперь ты в группе #{message.text}",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
    else
      user.department = nil
      user.department_name = nil

      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Группа #{message.text} не найдена. Доступные группы:\n#{user.groups.keys.join(" , ")}",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
      logger.warn "Reached code supposed to be unreachable!"
      msg = "User #{message.chat.id} (#{message.from.username}) tried to select group #{message.text} but it doesn't exist"
      logger.warn msg
      report msg
    end

    user.groups = {}
    user.state = :default
  end

  def send_week_schedule(_message, user)
    unless user.department && user.group
      bot.api.send_message(chat_id: user.id, text: "Группа не выбрана")
      return configure_group(_message, user)
    end

    unless user.department_name
      bot.api.send_message(
        chat_id: user.id,
        text:
          "В связи с техническими проблемами нужно выбрать группу заново. " \
          "Это нужно сделать один раз, больше такого не повторится."
      )
      return configure_group(_message, user)
    end

    sent_message = bot.api.send_message(
      chat_id: user.id,
      text: "Загружаю расписание...",
      reply_markup: {remove_keyboard: true}.to_json
    )

    schedule = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
      parser.fetch_schedule user.group_info
    end

    file_path = ImageGenerator.image_path(**user.group_info)
    make_photo = ->() { Faraday::UploadIO.new(file_path, 'image/png') }
    bot.api.send_photo(chat_id: user.id, photo: make_photo.call, reply_markup: DEFAULT_REPLY_MARKUP)
    unless schedule
      bot.api.send_message(
        chat_id: user.id,
        text:
          "Не удалось обновить расписание, *картинка может быть не актуальной!* Попробуйте позже.",
          parse_mode: 'Markdown',
        reply_markup: DEFAULT_REPLY_MARKUP
      )
      report("Failed to fetch schedule for #{user.group_info}", photo: make_photo.call)
    end
    bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)
  end

  def send_tomorrow_schedule(_message, user)
    unless user.department && user.group
      bot.api.send_message(chat_id: user.id, text: "Группа не выбрана")
      return configure_group(_message, user)
    end

    unless user.department_name
      bot.api.send_message(
        chat_id: user.id,
        text:
          "В связи с техническими проблемами нужно выбрать группу заново. " \
          "Это нужно сделать один раз, больше такого не повторится."
      )
      return configure_group(_message, user)
    end

    sent_message = bot.api.send_message(
      chat_id: user.id,
      text: "Загружаю расписание...",
      reply_markup: {remove_keyboard: true}.to_json
    )

    schedule = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
      parser.fetch_schedule user.group_info
    end

    day_index = Date.today.sunday? ? 0 : 1
    tomorrow_schedule = schedule && Schedule.from_raw(schedule).day(day_index)
    text = if tomorrow_schedule.nil? || tomorrow_schedule.all_empty?
      "Завтра нет пар!"
    else
      text = tomorrow_schedule.format
    end

    bot.api.send_message(
      chat_id: user.id,
      text:,
      parse_mode: 'Markdown',
      reply_markup: DEFAULT_REPLY_MARKUP
    )
    bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)
  end

  def send_left_schedule(_message, user)
    unless user.department && user.group
      bot.api.send_message(chat_id: user.id, text: "Группа не выбрана")
      return configure_group(_message, user)
    end

    unless user.department_name
      bot.api.send_message(
        chat_id: user.id,
        text:
          "В связи с техническими проблемами нужно выбрать группу заново. " \
          "Это нужно сделать один раз, больше такого не повторится."
      )
      return configure_group(_message, user)
    end

    if Date.today.sunday?
      bot.api.send_message(
        chat_id: user.id,
        text: "Сегодня воскресенье, отдыхай!",
        reply_markup: DEFAULT_REPLY_MARKUP)
      return
    end

    sent_message = bot.api.send_message(
      chat_id: user.id,
      text: "Загружаю расписание...",
      reply_markup: {remove_keyboard: true}.to_json
    )

    schedule = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
      parser.fetch_schedule user.group_info
    end
    left_schedule = schedule && Schedule.from_raw(schedule).left
    text = if left_schedule.nil? || left_schedule.all_empty?
      "Сегодня больше нет пар!"
    else
      left_schedule.format
    end

    bot.api.send_message(
      chat_id: user.id,
      text:,
      parse_mode: 'Markdown',
      reply_markup: DEFAULT_REPLY_MARKUP
    )
    bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)
  end

  def configure_sending(_message, user)
    unless user.department && user.group
      bot.api.send_message(chat_id: user.id, text: "Группа не выбрана")
      return configure_group(_message, user)
    end

    unless user.department_name
      bot.api.send_message(
        chat_id: user.id,
        text:
          "В связи с техническими проблемами нужно выбрать группу заново. " \
          "Это нужно сделать один раз, больше такого не повторится."
      )
      return configure_group(_message, user)
    end

    keyboard = [
      ["Отмена"],
      ["Ежедневная рассылка", "#{user.pair_sending ? 'Выкл.' : 'Вкл.'} рассылку перед парами"]
    ]
    bot.api.send_message(
      chat_id: user.id,
      text: "Что настроить?",
      reply_markup: {keyboard:, resize_keyboard: true, one_time_keyboard: true}.to_json
    )
    user.state = :select_senging_type
  end

  def configure_daily_sending(message, user)
    current_configuration = user.daily_sending ? " (сейчас: `#{user.daily_sending}`)" : ""
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Выберите время для ежедневной рассылки#{current_configuration}\nНапример: `7:00`",
      parse_mode: 'Markdown',
      reply_markup: {keyboard: [["Отмена"], ["Отключить"]], resize_keyboard: true, one_time_keyboard: true}.to_json
    )
    user.state = :configure_daily_sending
  end

  def set_daily_sending(message, user)
    fomratted_time = Time.parse(message.text).strftime('%H:%M')
    user.daily_sending = fomratted_time
    user.state = :default
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Ежедневная рассылка настроена на `#{fomratted_time}`",
      parse_mode: 'Markdown',
      reply_markup: DEFAULT_REPLY_MARKUP
    )
  end

  def disable_daily_sending(message, user)
    user.daily_sending = nil
    user.state = :default
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Ежедневная рассылка отключена",
      reply_markup: DEFAULT_REPLY_MARKUP
    )
  end

  def enable_pair_sending(message, user)
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "В разработке.",
      reply_markup: DEFAULT_REPLY_MARKUP
    )
    return
    user.pair_sending = true
    user.state = :default
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Рассылкка перед каждой парой включена",
      reply_markup: DEFAULT_REPLY_MARKUP
    )
  end

  def disable_pair_sending(message, user)
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "В разработке.",
      reply_markup: DEFAULT_REPLY_MARKUP
    )
    return
    user.pair_sending = false
    user.state = :default
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Рассылкка перед каждой парой выключена",
      reply_markup: DEFAULT_REPLY_MARKUP
    )
  end

  def debug_command(message, user)
    return unless ENV['DEBUG_CM']

    debug_command_name = message.text.split(' ').last
    logger.info "Calling test #{debug_command_name}..."
    unless DebugCommands.respond_to? debug_command_name
      logger.warn "Test #{debug_command_name} not found"
      bot.api.send_message(
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
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Нечего отменять",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
    else # :select_department, :select_group, :select_timer
      user.state = :default
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Действие отменено",
        reply_markup: DEFAULT_REPLY_MARKUP
      )
    end
  end
end

RaspishikaBot.new.run
