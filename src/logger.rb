# frozen_string_literal: true

require 'fileutils'
require 'logger'

module Raspishika
  class Formatter < ::Logger::Formatter
    COLOR_CODES = {
      black: 30, red: 31, green: 32, yellow: 33, blue: 34, magenta: 35, cyan: 36, white: 37, gray: 90, light_red: 91,
      light_green: 92, light_yellow: 93, light_blue: 94, light_magenta: 95, light_cyan: 96, light_white: 97
    }.freeze

    RESET_CODE = "\e[0m"

    def call(severity, time, progname, msg)
      color = severity_color severity
      msg_color = severity == 'INFO' ? nil : color

      severity_shorting = colorize severity[0], color
      formatted_time = colorize "[#{time.iso8601(6)}]", :gray
      severity = colorize severity.rjust(5), color
      progname = colorize progname, msg_color if msg_color
      msg = colorize msg, msg_color if msg_color

      "#{severity_shorting}, #{formatted_time} #{severity} -- #{progname}: #{msg}\n"
    end

    private

    def severity_color(severity)
      case severity
      when 'DEBUG' then :gray # :light_blue
      when 'INFO'  then :green
      when 'WARN'  then :yellow
      when 'ERROR' then :light_red
      when 'FATAL' then :red
      else :white
      end
    end

    def colorize(text, color)
      color_code = COLOR_CODES[color]
      return text unless color_code

      "\e[#{color_code}m#{text}#{Raspishika::Formatter::RESET_CODE}"
    end
  end

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
      @stderr_logger.formatter = Formatter.new
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
