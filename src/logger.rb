require 'logger'

class MyLogger
  def initialize
    @log_file = File.expand_path("../data/debug/#{Time.now.iso8601}.log", __dir__)

    @stderr_logger = Logger.new($stderr, level: Logger::DEBUG)
    @file_logger = Logger.new(log_file, level: Logger::DEBUG)
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
