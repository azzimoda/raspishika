# frozen_string_literal: true

require 'fileutils'
require 'logger'

module Raspishika
  class Logger
    attr_reader :log_file

    def initialize(file: true)
      @log_file = File.expand_path("../data/debug/#{Time.now.iso8601}.log", __dir__) if file

      delete_old_logs

      level =
        case OPTIONS[:log_level]
        when 'debug' then ::Logger::DEBUG
        when 'info' then ::Logger::INFO
        when 'warn' then ::Logger::WARN
        when 'error' then ::Logger::ERROR
        when 'fatal' then ::Logger::FATAL
        else
          puts "Unkonwn log level #{OPTIONS[:log_level]}, defaulting to debug"
          ::Logger::DEBUG
        end

      @stderr_logger = ::Logger.new($stderr, level: level)
      return unless @log_file

      FileUtils.mkdir_p File.dirname @log_file
      @file_logger = ::Logger.new @log_file, level: level
    end

    def delete_old_logs
      files = Dir.glob(File.expand_path('../data/debug/*.log', __dir__))
      files.sort_by { File.mtime it }.reverse.drop(100).each { File.delete it }
    end

    %w[debug info warn error fatal unknown].each do |level|
      define_method level do |progname = nil, &block|
        @stderr_logger.send(level, progname, &block)
        @file_logger&.send(level, progname, &block)
      end
    end
  end

  # The module provides delegated method `logger` to the module `Raspishika`.
  # Include it in a class or extend a module with it to have access to the global logger instance.
  module GlobalLogger
    module_function

    def logger
      Raspishika.logger
    end
  end

  module_function

  # Returns global logger instance.
  def logger
    @logger ||= Logger.new
  end

  # Resets global logger instance with given arguments.
  def logger!(...)
    @logger = Logger.new(...)
  end
end
