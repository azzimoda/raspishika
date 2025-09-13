# frozen_string_literal: true

require 'pstore'

module Raspishika
  module Cache
    DEFAULT_CACHE_EXPIRATION = 15 * 60 # 15 minutes
    @logger = nil
    @data = {}
    file = File.expand_path '../data/cache.pstore', __dir__
    FileUtils.mkdir_p File.dirname file
    @store = PStore.new file
    @cache_mutex = Mutex.new
    @store_mutex = Mutex.new

    class << self
      attr_accessor :logger
    end

    # If `expires_in` is `nil`, the cache will not expire. If `expires_in` is 0, the will be always expired.
    def self.fetch(
      key, expires_in: DEFAULT_CACHE_EXPIRATION, allow_nil: false, file: false, log: true, unsafe: false, &block
    )
      if DEFAULT_CACHE_EXPIRATION.zero?
        logger&.debug "Skipping caching for #{key.inspect} because of environment configuration..." if log
        return block.call
      end

      return transaction(key, expires_in: expires_in, allow_nil: allow_nil, file: file, log: log, &block) if unsafe

      @cache_mutex.synchronize do
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

    def self.actual_entry?(entry, expires_in:, allow_nil: false)
      entry && (allow_nil || entry[:value]) && (expires_in.nil? || Time.now - entry[:timestamp] < expires_in)
    end

    # If `expires_in` is `nil`, the cache will not expire. If `expires_in` is 0, the will be always expired.
    def self.get(key, file: false, expires_in: nil)
      entry = get_entry(key, file: file)
      return unless actual_entry? entry, expires_in: expires_in

      entry[:value]
    end

    def self.get_entry(key, file: false)
      @store_mutex.synchronize do
        if file
          @store.transaction(true) { @store[key] if @store.root? key }
        else
          @data[key]
        end
      end
    end

    def self.set(key, value, file: false)
      new_cache = { value: value, timestamp: Time.now }
      @store_mutex.synchronize do
        if file
          @store.transaction { (@store[key] = new_cache)[:value] }
        else
          (@data[key] = new_cache)[:value]
        end
      end
    end

    def self.clear
      @store_mutex.synchronize { @data.clear }
    end
  end
end
