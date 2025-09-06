# frozen_string_literal: true

require 'yaml'

module Raspishika
  module Config
    CONFIG_FILE = File.expand_path '../config/config.yml', __dir__

    def self.[](key)
      @config ||= load_config
      @config[key]
    end

    def self.load_config
      @config = YAML.load_file CONFIG_FILE, symbolize_names: true
    end
  end
end
