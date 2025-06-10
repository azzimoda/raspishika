require 'logger'

module Raspishika
  class Logger
    def initialize
      @log_file = File.expand_path("../data/debug/#{Time.now.iso8601}.log", __dir__)
  
      level = case ENV['LOGGER']&.downcase
      when 'debug' then ::Logger::DEBUG
      when 'info' then ::Logger::INFO
      when 'warn' then ::Logger::WARN
      when 'error' then ::Logger::ERROR
      when 'fatal' then ::Logger::FATAL
      else ::Logger::DEBUG
      end
  
      @stderr_logger = ::Logger.new($stderr, level:)
      @file_logger = ::Logger.new(log_file, level:)
    end
    attr_reader :log_file
  
    def debug(msg, &block)
      @stderr_logger.debug(msg, &block)
      @file_logger.debug(msg, &block)
    end
  
    def info(msg, &block)
      @stderr_logger.info(msg, &block)
      @file_logger.info(msg, &block)
    end
  
    def warn(msg, &block)
      @stderr_logger.warn(msg, &block)
      @file_logger.warn(msg, &block)
    end
  
    def error(msg, &block)
      @stderr_logger.error(msg, &block)
      @file_logger.error(msg, &block)
    end
  
    def fatal(msg, &block)
      @stderr_logger.fatal(msg, &block)
      @file_logger.fatal(msg, &block)
    end
  
    def unknown(msg, &block)
      @stderr_logger.unknown(msg, &block)
      @file_logger.unknown(msg, &block)
    end
  end
end
