require 'logger'
require 'telegram/bot'
require 'nokogiri'
require 'open-uri'
require 'uri'
require 'cgi'
require 'selenium-webdriver'
require 'timeout'

require './parser'
require './debug_commands'

if ENV['TELEGRAM_BOT_TOKEN'].nil?
  puts "Environment variable TELEGRAM_BOT_TOKEN is nil"
  quit
end
DEFAULT_KEYBOARD = [[]]

logger = Logger.new($stderr, level: Logger::DEBUG)
parser = ScheduleParser.new(logger: logger)

logger.info "Starting bot..."
Telegram::Bot::Client.run(ENV['TELEGRAM_BOT_TOKEN']) do |bot|
  bot.listen do |message|
    logger.debug "Received: #{message.text}"
    begin
      case message.text.downcase
      when '/start'
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Привет! Используй /departments чтобы начать",
          reply_markup: { remove_keyboard: true }.to_json
        )
      
      when '/help'
        # TODO: /help
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Помощи не будет(",
          reply_markup: { remove_keyboard: true }.to_json
        )

      when '/departments' || 'отделения'
        departments = parser.fetch_departments
        if departments.any?
          # keyboard = pp departments.keys.each_slice(2).map { |pair| pair.map { |name| { text: name } } }
          keyboard = pp departments.keys.each_slice(2).to_a

          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Выберите отделение:",
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
            reply_markup: { remove_keyboard: true }.to_json
          )
          next
        end

        DebugCommands.send(test_name, bot, parser, logger)

      else
        context = parser.user_context[message.chat.id]
        unless context
          # If there's no context it's department selection
          departments = parser.fetch_departments
          if departments.key? message.text
            parser.user_context[message.chat.id] = {
              department: message.text,
              department_url: departments[message.text]
            }

            groups = parser.fetch_groups departments[message.text]
            if groups.any?
              keyboard = groups.keys.each_slice(2).to_a

              bot.api.send_message(
                chat_id: message.chat.id,
                text: "Выберите группу:",
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
              text: "Пожалуйста, выберите отделение из списка",
              reply_markup: { remove_keyboard: true }.to_json
            )
          end

        else
          # If there's context it's group selection
          groups = parser.fetch_groups context[:department_url]

          logger.debug "User context: #{parser.user_context.inspect}"
          # logger.debug "Groups: #{groups.inspect}"

          if (group_info = groups[message.text])
            bot.api.send_message(
              chat_id: message.chat.id,
              text: "Загружаю расписание, пожалуйста подождите...",
              reply_markup: { remove_keyboard: true }.to_json
            )

            schedule = format_schedule_days transform_schedule_to_days parser.fetch_schedule group_info
            if schedule.empty?
              text = "Расписание не найдено"
              logger.warn "Schedule not found!"
            end
            bot.api.send_message(
              chat_id: message.chat.id,
              text: schedule.empty? ? "Расписание не найдено" : schedule,
              reply_markup: { remove_keyboard: true }.to_json
            )
          else
            bot.api.send_message(
              chat_id: message.chat.id,
              text: "Группа #{message.text} не найдена. Доступные группы:\n#{groups.keys.join(" , ")}",
              reply_markup: { remove_keyboard: true }.to_json
            )
          end

          parser.user_context.delete message.chat.id
        end
      end
    rescue => e
      logger.error "Error: #{e.message}\n#{e.backtrace.join("\n")}"
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Произошла ошибка. Попробуйте позже.",
        reply_markup: { remove_keyboard: true }.to_json
      )
      # TODO: report_error(e)
    end
  end
rescue Interrupt
  puts
  logger.warn "Keyboard interruption"
end
