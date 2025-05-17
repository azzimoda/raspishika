require 'logger'

class MyLogger
  def initialize
    @log_file = File.expand_path("../data/debug/#{Time.now.iso8601}.log", __dir__)

    @stderr_logger = Logger.new($stderr, level: Logger::DEBUG)
    @file_logger = Logger.new(log_file, level: Logger::DEBUG)
  end
  attr_reader :log_file

  def debug(msg)
    @stderr_logger.debug(msg)
    @file_logger.debug(msg)
  end

  def info(msg)
    @stderr_logger.info(msg)
    @file_logger.info(msg)
  end

  def warn(msg)
    @stderr_logger.warn(msg)
    @file_logger.warn(msg)
  end

  def error(msg)
    @stderr_logger.error(msg)
    @file_logger.error(msg)
  end

  def fatal(msg)
    @stderr_logger.fatal(msg)
    @file_logger.fatal(msg)
  end

  def unknown(msg)
    @stderr_logger.unknown(msg)
    @file_logger.unknown(msg)
  end
end
