require 'pstore'

module Raspishika
  module Cache
    DEFAULT_CACHE_EXPIRATION = 15*60 # 15 minutes
    @logger = nil
    @data = {}
    @store = PStore.new File.expand_path 'data/cache.pstore', ROOT_DIR
    @mutex = Mutex.new

    class << self
      attr_accessor :logger
    end

    # If expires_in is nil, the cache will not expire. If expires_in is 0, the will be always expired.
    def self.fetch(key, expires_in: DEFAULT_CACHE_EXPIRATION, allow_nil: false, file: false, &block)
      if DEFAULT_CACHE_EXPIRATION.zero?
        logger&.debug "Skipping caching for #{key.inspect} because of environment configuration..."
        return block.call
      end

      if @mutex.locked?
        transaction(key, expires_in:, allow_nil:, file:, &block)
      else
        @mutex.synchronize { transaction(key, expires_in:, allow_nil:, file:, &block) }
      end
    end

    def self.transaction(key, expires_in:, allow_nil:, file:, &block)
      entry = if file
        @store.transaction true do
          break nil unless @store.root? key
          @store[key]
        end
      else
        @data[key]
      end

      if (entry && (allow_nil || entry[:value]) && (expires_in.nil? || Time.now - entry[:timestamp] < expires_in))
        logger&.debug "Returning existing cache for #{key.inspect}..."
        entry[:value].dup
      else
        logger&.debug "Generating new cache for #{key.inspect}..."
        new_cache = { value: block.call, timestamp: Time.now }
        if file
          @store.transaction do
            @store[key] = new_cache
            @store[key][:value].dup
          end
        else
          @data[key] = new_cache
          @data[key][:value].dup
        end
      end
    end

    def self.actual?(key, expires_in: DEFAULT_CACHE_EXPIRATION, allow_nil: false, file: false)
      entry = if file
        @store.transaction true do
          break nil unless @store.root? key
          @store[key]
        end
      else
        @data[key]
      end
      entry && (allow_nil || entry[:value]) && (expires_in.nil? || Time.now - entry[:timestamp] < expires_in)
    end

    def self.get(key, file: false)
      if file
        @store.transaction true do
          break nil unless @store.root? key
          @store[key][:value]
        end
      else
        @data[key][:value] if @data[key]
      end
    end

<<<<<<< HEAD
    def self.set(key, value, file: false)
      new_cache = { value: value, timestamp: Time.now }
      if file
        @store.transaction do
          (@store[key] = new_cache).dup
        end
      else
        (@data[key] = new_cache).dup
      end
=======
    def self.actual?(key, expires_in: DEFAULT_CACHE_EXPIRATION, allow_nil: false)
      entry = @data[key]
      entry && (allow_nil || entry[:value]) && (expires_in.nil? || Time.now - entry[:timestamp] < expires_in)
    end

    def self.get(key)
      @data[key][:value] if @data[key]
    end

    def self.set(key, value)
      @data[key] = { value: value, timestamp: Time.now }
>>>>>>> 58b2dc2
    end

    def self.clear
      @mutex.synchronize { @data.clear }
    end
  end
end
