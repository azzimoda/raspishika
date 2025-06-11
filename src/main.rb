require 'concurrent'
require 'telegram/bot'
require 'date'
require 'rufus-scheduler'

require_relative 'cache'
require_relative 'parser'
require_relative 'schedule'
require_relative 'user'
require_relative 'logger'

require_relative 'commands'
require_relative 'debug_commands'
require_relative 'dev_bot'

module Raspishika
  if (message = ENV['NOTIFY'])
    require_relative 'notification'
  
    User.logger = ::Logger.new($stdout, ::Logger::DEBUG)
    User.restore
    notify message
    exit
  end

  if ENV['TELEGRAM_BOT_TOKEN'].nil?
    puts "FATAL: Environment variable TELEGRAM_BOT_TOKEN is nil"
    quit
  end
  
  LABELS = {
    left: 'Оставшиеся пары',
    tomorrow: 'Завтра',
    week: 'Неделя',
    select_group: 'Выбрать группу',
    configure_sending: 'Настроить рассылку',
    daily_sending: 'Ежедневная рассылка',
    pair_sending_on: 'Вкл. рассылку перед парами',
    pair_sending_off: 'Выкл. рассылку перед парами',
    quick_schedule: 'Быстрое расписание',
  }
  MAX_RETRIES = 5
  
  class Bot
    THEAD_POOL_SIZE = 20
  
    DEFAULT_KEYBOARD = [
      [LABELS[:left]],
      [LABELS[:tomorrow], LABELS[:week]],
      [LABELS[:quick_schedule], LABELS[:select_group], LABELS[:configure_sending]],
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
  
    MY_COMMANDS = [
      {command: 'left', description: 'Оставшиеся пары'},
      {command: 'tomorrow', description: 'Расписание на завтра'},
      {command: 'week', description: 'Расписание на неделю'},
      {command: 'quick_schedule', description: 'Быстрое расписание другой группы'},
      {command: 'configure_sending', description: 'Настроить рассылку'},
      {command: 'configure_daily_sending', description: 'Настроить ежедневную рассылку'},
      {command: 'daily_sending_off', description: 'Выключить ежедневную рассылку'},
      {command: 'pair_sending_on', description: 'Включить рассылку перед парами'},
      {command: 'pair_sending_off', description: 'Выключить рассылку перед парами'},
      {command: 'set_group', description: 'Изменить группу'},
      {command: 'cancel', description: 'Отменить действие'},
      {command: 'stop', description: 'Остановить бота и удалить данные о себе'},
      {command: 'help', description: 'Помощь'},
      {command: 'start', description: 'Запуск бота'}
    ]
  
    def initialize
      @logger = Raspishika::Logger.new
      @scheduler = Rufus::Scheduler.new
      @parser = ScheduleParser.new(logger: @logger)
      @thread_pool = Concurrent::FixedThreadPool.new THEAD_POOL_SIZE
      @retries = 0
  
      @token = ENV['TELEGRAM_BOT_TOKEN']
      @run = true
      @dev_bot = DevBot.new logger: @logger
      @username = nil
  
      ImageGenerator.logger = Cache.logger = User.logger = @logger
      User.restore
    end
    attr_accessor :bot, :logger, :parser, :username
  
    def run
      logger.info "Starting bot..."
      @user_backup_thread = Thread.new(self, &:user_backup_loop)
  
      @dev_bot_thread = Thread.new(@dev_bot, &:run)
  
      @parser.initialize_browser_thread
      sleep 1 until @parser.ready?
  
      Telegram::Bot::Client.run(@token) do |bot|
        @bot = bot
        @username = bot.api.get_me.username
        logger.debug "Bot's username: #{@username}"
  
        report "Bot started."
  
        bot.api.set_my_commands(commands: MY_COMMANDS)
  
        schedule_pair_sending
        @sending_thread = Thread.new(self, &:daily_sending_loop)
  
        begin
          logger.info "Starting bot listen loop..."
          bot.listen { |message| handle_message message }
        rescue Telegram::Bot::Exceptions::ResponseError => e
          "Telegram API error: #{e.detailed_message}".tap do |msg|
            logger.error msg
            logger.error "Retrying... (#{@retries + 1}/#{MAX_RETRIES})"
            report(msg, backtrace: e.backtrace.join("\n"))
          end
  
          sleep 5
          @retries += 1
          retry if @retries < MAX_RETRIES
          "Reached maximum retries! Stopping bot...".tap do |msg|
            logger.fatal msg
            report "FATAL ERROR: #{msg}"
          end
        rescue => e
          "Unhandled error in `bot.listen`: #{e.detailed_message}".tap do |msg|
            logger.error msg
            logger.error "Retrying... (#{@retries + 1}/#{MAX_RETRIES})"
            report(msg, backtrace: e.backtrace.join("\n"))
          end
  
          sleep 5
          @retries += 1
          retry if @retries < MAX_RETRIES
          "Reached maximum retries! Stopping bot...".tap do |msg|
            logger.fatal msg
            report "FATAL ERROR: #{msg}"
          end
        end
      end
    rescue Interrupt
      puts
      logger.warn "Keyboard interruption"
    rescue => e
      puts
      logger.fatal "Unhandled error in the main method (#run):"
      logger.fatal e.detailed_message
      logger.fatal e.backtrace.join "\n"
    ensure
      report "Bot stopped."
      @run = false
  
      @user_backup_thread&.join
      User.backup
  
      @dev_bot_thread&.kill
      @sending_thread&.join
      @parser.stop_browser_thread
  
      @thread_pool&.shutdown
      @thread_pool&.wait_for_termination(30)
      @thread_pool&.kill if @thread_pool.running?
    end
  
    def user_backup_loop
      while @run
        User.backup
        (600).times do
          break unless @run
          sleep 1
        end
      end
    end
  
    def daily_sending_loop
      logger.info "Starting daily sending loop..."
      last_sending_time = Time.now - 10*60
  
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
              conf_time: it.daily_sending, process_time: Time.now - start_time, ok: true)
          rescue => e
            user.push_daily_sending_report(
              conf_time: it.daily_sending, process_time: Time.now - start_time, ok: false)
            msg = "Error while sending daily schedule: #{e.detailed_message}"
            backtrace = e.backtrace.join("\n")
            logger.error msg
            logger.error backtrace
            report(msg, backtrace:)
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
      logger.info "Scheduling pair sending..."
  
      ['8:00', '9:45', '11:30', '13:45', '15:30', '17:15', '19:00'].each do |time|
        logger.debug "Scheduling sending for #{time}..."
        time = Time.parse time
  
        sending_time = time - 15 * 60
        @scheduler.cron("#{sending_time.min} #{sending_time.hour} * * 1-6") do
          send_pair_notification time
        end
      end
    end
  
    private
  
    def send_pair_notification time, user: nil
      logger.info "Sending pair notification for #{time}..."
  
      groups = if user
        logger.debug "Sending pair notification for #{time} to #{user.id} with group #{user.group_info}..."
        {[user.department, user.group] => [user]}
      else
        User.users.values.select(&:pair_sending).group_by { [it.department, it.group] }
      end
      logger.debug "Sending pair notification to #{groups.size} groups..."
  
      futures = groups.map do |(sid, gr), users|
        Concurrent::Future.execute(executor: @thread_pool) do
          send_pair_notification_for_group(sid:, gr:, users:, time:)
        rescue => e
          logger.error "Failed to send pair notification for group #{gr}: #{e.detailed_message}"
          logger.error e.backtrace.join("\n")
        end
      end
      futures.each(&:wait)
    end
  
    def send_pair_notification_for_group(sid:, gr:, users:, time:)
      return unless sid && gr
      return if users.empty? # NOTE: Maybe it's useless line.
  
      raw_schedule = Cache.fetch(:"schedule_#{sid}_#{gr}") do
        @parser.fetch_schedule users.first.group_info
      end
      if raw_schedule.nil?
        logger.error "Failed to fetch schedule for #{users.first.group_info}"
        return
      end
  
      pair = Schedule.from_raw(raw_schedule).now(time:)&.pair(0)
      return unless pair
  
      text = case pair.data.dig(0, :pairs, 0, :type)
      when :subject, :exam, :consultation
        "Следующая пара в кабинете %{classroom}:\n%{discipline}\n%{teacher}" %
          pair.data.dig(0, :pairs, 0, :content)
      else
        logger.debug "No pairs left for the group"
        return
      end
  
      logger.debug "Sending pair notification to #{users.size} users of group #{users.first.group_info[:group_name]}..."
      users.map(&:id).each do |chat_id|
        bot.api.send_message(chat_id:, text:)
      rescue => e
        logger.error "Failed to send pair notification of group #{gr} to #{chat_id}: #{e.detailed_message}"
        logger.error e.backtrace.join("\n\t")
      end
    end
  
    def report(*args, **kwargs)
      @dev_bot.report(*args, **kwargs)
    end
  
    def handle_message message
      case message
      when Telegram::Bot::Types::Message then handle_text_message message
      else logger.debug "Unhandled message type: #{message.class}"
      end
    end
  
    def handle_text_message message
      return unless message.text
  
      begin
        msg_text = message.text.size > 32 ? message.text[0...32] + '…' : message.text
        logger.debug(
          "Received: #{msg_text} from #{message.chat.id}" \
          " (@#{message.from.username}, #{message.from.first_name} #{message.from.last_name})"
        )
    
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
        when '/set_group', LABELS[:select_group].downcase then configure_group message, user
        when ->(t) { user.state.start_with?('select_department') && user.departments.map(&:downcase).include?(t) }
          select_department message, user
        when ->(t) { user.groups.keys.map(&:downcase).include?(t) }
          select_group message, user
        when '/week', LABELS[:week].downcase then send_week_schedule message, user
        when '/tomorrow', LABELS[:tomorrow].downcase then send_tomorrow_schedule message, user
        when '/left', LABELS[:left].downcase then send_left_schedule message, user
        when '/quick_schedule', LABELS[:quick_schedule].downcase
          configure_group(message, user, quick: true)
        when '/configure_sending', LABELS[:configure_sending].downcase
          configure_sending message, user
        when '/configure_daily_sending', 'ежедневная рассылка'
          configure_daily_sending message, user
        when %r(^\d{1,2}:\d{2}$)
          if (message.text =~ %r(^\d{1,2}:\d{2}$) && Time.parse(message.text) rescue false)
            set_daily_sending message, user
          else
            bot.api.send_message(
              chat_id: message.chat.id,
              text: "Неправильный формат времени, попробуйте ещё раз",
            )
          end
        when '/daily_sending_off', 'отключить' then disable_daily_sending message, user
        when '/pair_sending_on', LABELS[:pair_sending_on].downcase
          enable_pair_sending message, user
        when '/pair_sending_off', LABELS[:pair_sending_off].downcase
          disable_pair_sending message, user
        when '/cancel', 'отмена' then cancel_action message, user
        when %r(^/debug\s+\w+$) then debug_command message, user
        # else
        #   logger.debug "Unhandled text message:" \
        #     " #{message.text.size > 64 ? message.text[0..63] + '...' : message.text}"
        end
      rescue => e
        msg =
          "Unhandled error in `#handle_text_message`: #{e.detailed_message}\n" \
          "\tFrom #{message.chat.id} (#{message.from.username}); message #{message.text.inspect}"
        logger.error msg
        logger.debug e.backtrace.join"\n"
        report(msg, backtrace: e.backtrace.join("\n"), log: nil)
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Произошла ошибка. Попробуйте позже.",
          reply_markup: message.chat.id < 0 ? DEFAULT_REPLY_MARKUP : nil
        )
      end
    end
  end
end

Raspishika::Bot.new.run
