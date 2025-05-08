require 'logger'
require 'telegram/bot'
require 'nokogiri'
require 'open-uri'
require 'uri'
require 'cgi'
require 'selenium-webdriver'
require 'timeout'

require './cache'
require './user'
require './parser'
require './debug_commands'

if ENV['TELEGRAM_BOT_TOKEN'].nil?
  puts "Environment variable TELEGRAM_BOT_TOKEN is nil"
  quit
end
DEFAULT_KEYBOARD = [
  ["Оставшиеся пары"],
  ["Сегодня/Завтра", "На неделю"],
  ["Выбрать группу"]
]

logger = Logger.new($stderr, level: Logger::DEBUG)
parser = ScheduleParser.new(logger: logger)
User.logger = logger

logger.info "Starting bot..."
Telegram::Bot::Client.run(ENV['TELEGRAM_BOT_TOKEN']) do |bot|
  bot.api.set_my_commands(
    commands: [
      { command: 'start', description: 'Запуск бота' },
      { command: 'help', description: 'Помощь' },
      { command: 'departments', description: 'Список отделений/групп' },
      { command: 'set_group', description: 'Выбрать группу' },
      { command: 'set_timer', description: 'Задать таймер' },
      { command: 'off_timer', description: 'Выключить таймер' },
    ]
  )

  bot.listen do |message|
    logger.debug "Received: #{message.text}"
    begin
      user = User[message.chat.id]
      case message.text.downcase
      when '/start'
        bot.api.send_message(
          chat_id: message.chat.id,
          text:
            "Привет! Используй /set_group чтобы задать группу для регулярного расписания " \
            "и кнопки ниже для других действий.",
          reply_markup: {
            keyboard: DEFAULT_KEYBOARD,
            resize_keyboard: true,
            one_time_keyboard: true,
          }.to_json
        )

      # TODO: /help
      when '/help'
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Помощи не будет(",
          reply_markup: {
            keyboard: DEFAULT_KEYBOARD,
            resize_keyboard: true,
            one_time_keyboard: true,
          }.to_json
        )

      when '/set_group', 'выбрать группу'
        departments = Cache.fetch(:departments) { parser.fetch_departments }
        if departments.any?
          user.departments = departments.keys
          user.state = :select_department

          keyboard = departments.keys.each_slice(2).to_a
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Выбери отделение",
            reply_markup: {
              keyboard: keyboard,
              resize_keyboard: true,
              one_time_keyboard: true
            }.to_json
          )
        else
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Не удалось загрузить отделения",
            reply_markup: { remove_keyboard: true }.to_json
          )
        end

      when ->(t) { user.departments.map(&:downcase).include?(t) }
        departments = Cache.fetch(:departments, expires_in: 300) { parser.fetch_departments }
        # Additional check
        if departments.key? message.text
          groups = Cache.fetch(:groups, expires_in: 300) { parser.fetch_groups departments[message.text] }
          if groups.any?
            user.department = [message.text]
            user.department_url = departments[message.text]
            user.departments = []
            user.state = :select_group

            keyboard = groups.keys.each_slice(2).to_a
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
              reply_markup: { remove_keyboard: true }.to_json
            )
          end
        else
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Пожалуйста, выбери отделение из списка",
            reply_markup: { remove_keyboard: true }.to_json
          )
        end

      # TODO: Ask whether select the group or not.
      when ->(t) { user.groups.map(&:downcase).include?(t) }
        # TODO: Add loading "animation"...
        sent_message = bot.api.send_message(
          chat_id: message.chat.id,
          text: "Загружаю расписание...",
          reply_markup: { remove_keyboard: true }.to_json
        )
        logger.debug "Sent message #{sent_message.inspect}"
        groups = Cache.fetch(:groups, expires_in: 300) { parser.fetch_groups user.department_url }

        if (group_info = groups[message.text])
          schedule = Cache.fetch(:schedule, expires_in: 300) { parser.fetch_schedule group_info }
          schedule = format_schedule_days transform_schedule_to_days schedule
          unless schedule.strip.empty?
            text = schedule
          else
            logger.warn "Schedule not found!"
            text = "Расписание не найдено"
          end
          # TODO: Understand why it says the message can't be edited.
          # bot.api.edit_message_text(
          #   chat_id: sent_message.chat.id,
          #   message_id: sent_message.message_id,
          #   text: text,
          #   reply_markup: {
          #     keyboard: DEFAULT_KEYBOARD,
          #     resize_keyboard: true,
          #     one_time_keyboard: true,
          #   }.to_json
          # )
          bot.api.send_message(
            chat_id: message.chat.id,
            text: text,
            reply_markup: {
              keyboard: DEFAULT_KEYBOARD,
              resize_keyboard: true,
              one_time_keyboard: true,
            }.to_json
          )
        else
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Группа #{message.text} не найдена. Доступные группы:\n#{groups.keys.join(" , ")}",
            reply_markup: {
              keyboard: DEFAULT_KEYBOARD,
              resize_keyboard: true,
              one_time_keyboard: true,
            }.to_json
          )
        end

        user.state = :default

    # TODO: Set timer
      when '/set_timer', 'задать таймер'
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Таймер не реализован",
        )
        # User have 2 variants: once per day, before each pair, off, cancel

      when %r(^/test\s+\w+$)
        next unless ENV['TEST']

        test_name = message.text.split(' ').last
        logger.info "Calling test #{test_name}..."

        unless DebugCommands.respond_to? test_name
          logger.warn "Test #{test_name} not found"
          bot.api.send_message(
            chat_id: message.chat.id,
            text:
              "Тест `#{test_name}` не найден.\n\n" \
              "Доступные тесты: #{DebugCommands.methods.join(', ')}",
            reply_markup: {
              keyboard: DEFAULT_KEYBOARD,
              resize_keyboard: true,
              one_time_keyboard: true,
            }.to_json
          )
          next
        end

        DebugCommands.send(test_name, bot, parser, logger)

      else
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Я не знаю как ответить на это сообщение :( Используй /help",
          reply_markup: {
            keyboard: DEFAULT_KEYBOARD,
            resize_keyboard: true,
            one_time_keyboard: true,
          }.to_json
        )
      end
    rescue => e
      logger.error "Error: #{e.message}\n#{e.backtrace.join("\n")}"
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Произошла ошибка. Попробуйте позже.",
        reply_markup: {
          keyboard: DEFAULT_KEYBOARD,
          resize_keyboard: true,
          one_time_keyboard: true,
        }.to_json
      )
      # TODO: report_error_ro_developer(e)
    end
  end
rescue Interrupt
  puts
  logger.warn "Keyboard interruption"
end
