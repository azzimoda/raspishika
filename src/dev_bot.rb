require 'json'
require 'telegram/bot'

require_relative 'user'

class RaspishikaDevBot
  ADMIN_CHAT_ID_FILE = File.expand_path('../data/admin_chat_id', __dir__).freeze

  def initialize logger: nil
    @logger = logger || Logger.new($stderr, level: Logger::ERROR)
    @token = ENV['DEV_BOT_TOKEN']
    @admin_chat_id = File.read(ADMIN_CHAT_ID_FILE).chomp.to_i rescue nil
    @run = ENV['DEV_BOT'] ? ENV['DEV_BOT'] == 'true' : true
  end
  attr_accessor :logger, :bot

  def run
    return unless @run
    unless @token
      logger.warn "Token for statistics bot is not set! It won't run."
      return
    end

    logger.info "Starting statistics bot..."
    Telegram::Bot::Client.run(@token) do |bot|
      @bot = bot
      bot.api.set_my_commands(
        commands: [
          {command: 'start', description: 'Start'},
          {command: 'help', description: 'No help'},
          {command: 'log', description: 'Get last log'},
        ]
      )
      bot.listen { handle_message it }
    end
  rescue Interrupt
    puts
    puts "Keyboard interruption"
  ensure
    File.write(ADMIN_CHAT_ID_FILE, @admin_chat_id.to_s) if @admin_chat_id
  end

  def report text, photo: nil, backtrace: nil, log: nil
    return unless @token && @admin_chat_id && @run

    logger.info "Sending report #{text.inspect}..."
    bot.api.send_photo(chat_id: @admin_chat_id, photo:) if photo
    if log
      bot.api.send_message(
        chat_id: @admin_chat_id,
        text: "LOGS:\n```\n#{last_log lines: log}\n```",
        parse_mode: 'Markdown'
      )
    end
    if backtrace
      bot.api.send_message(
        chat_id: @admin_chat_id,
        text: "BACKTRACE:\n```\n#{backtrace}\n```",
        parse_mode: 'Markdown'
      )
    end
    bot.api.send_message(chat_id: @admin_chat_id, text:)
  end

  private

  def handle_message message
    case message.text.downcase
    when '/start' then @admin_chat_id = message.chat.id
    when ->(*) { @admin_chat_id.nil? } then return
    when %r(/log\s+(\d+)) then send_log message, lines: Regexp.last_match(1).to_i
    when '/log' then send_log message
    when '/stats' then send_stats message
    else bot.api.send_message(chat_id: message.chat.id, text: "Huh?")
    end
  end

  def send_stats message
    bot.api.send_message(chat_id: message.chat.id, text: "Nothing yet(")
  end

  def send_log message, lines: 20
    log = last_log(lines:)
    if log && !log.empty?
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "```\n#{log}\n```",
        parse_mode: 'Markdown'
      )
    else
      bot.api.send_message(chat_id: message.chat.id, text: "No log.")
    end
  end

  def last_log lines: 20
    File.exist?(logger.log_file) ? `tail -n #{lines} #{logger.log_file.shellescape}` : ''
  rescue => e
    "Failed to get last log: #{e.detailed_message}".tap { logger.error it; report it }
    ''
  end
end
