# frozen_string_literal: true

require 'pstore'

module Raspishika
  module Cache
    DEFAULT_CACHE_EXPIRATION = 15 * 60 # 15 minutes
    @logger = nil
    @data = {}
    @store = PStore.new File.expand_path 'data/cache.pstore', ROOT_DIR
    @mutex = Mutex.new

    class << self
      attr_accessor :logger
    end

    # If `expires_in` is `nil`, the cache will not expire. If `expires_in` is 0, the will be always expired.
    def self.fetch(key, expires_in: DEFAULT_CACHE_EXPIRATION, allow_nil: false, file: false, log: true, &block)
      if DEFAULT_CACHE_EXPIRATION.zero?
        logger&.debug "Skipping caching for #{key.inspect} because of environment configuration..." if log
        return block.call
      end

      if @mutex.locked?
        return transaction(key, expires_in: expires_in, allow_nil: allow_nil, file: file, log: log, &block)
      end

      @mutex.synchronize do
        transaction(key, expires_in: expires_in, allow_nil: allow_nil, file: file, log: log, &block)
      end
    end

    def self.transaction(key, expires_in:, allow_nil:, file:, log: true, &block)
      entry = get_entry key, file: file

      if actual_entry? entry, expires_in: expires_in, allow_nil: allow_nil
        logger&.debug "Returning existing cache for #{key.inspect}..." if log
        entry[:value].dup
      else
        logger&.debug "Generating new cache for #{key.inspect}..." if log
        set key, block.call, file: file
      end
    end

    def self.actual?(key, expires_in: DEFAULT_CACHE_EXPIRATION, allow_nil: false, file: false)
      entry = get_entry key, file: file
      actual_entry? entry, expires_in: expires_in, allow_nil: allow_nil
    end

    def self.actual_entry?(entry, expires_in:, allow_nil:)
      entry && (allow_nil || entry[:value]) && (expires_in.nil? || Time.now - entry[:timestamp] < expires_in)
    end

    def self.get(key, file: false)
      get_entry(key, file: file)&.dig(:value)
    end

    def self.get_entry(key, file: false)
      if file
        @store.transaction(true) { @store[key] if @store.root? key }
      elsif @data[key]
        @data[key]
      end
    end

    def self.set(key, value, file: false)
      new_cache = { value: value, timestamp: Time.now }
      if file
        @store.transaction { (@store[key] = new_cache)[:value] }
      else
        (@data[key] = new_cache)[:value]
      end
    end

    def self.clear
      @mutex.synchronize { @data.clear }
    end
  end
end
