module Raspishika
  module Cache
    DEFAULT_CACHE_EXPIRATION = 10*60 # 10 minutes
    @logger = nil
    @data = {}
    @mutex = Mutex.new

    class << self
      attr_accessor :logger
    end

    # If expires_in is nil, the cache will not expire. If expires_in is 0, the will be always expired.
    def self.fetch(key, expires_in: DEFAULT_CACHE_EXPIRATION, allow_nil: false, log: true, &block)
      if DEFAULT_CACHE_EXPIRATION.zero?
        logger&.debug "Skipping caching for #{key.inspect} because of environment configuration..." if log
        return block.call
      end

      # TODO: Come up with a better way to prevent Mutex deadlocks.
      foo = lambda do
        entry = @data[key]
        if (entry &&
            (allow_nil || entry[:value]) &&
            (expires_in.nil? || Time.now - entry[:timestamp] < expires_in))
          logger&.debug "Returning existing cache for #{key.inspect}..." if log
          entry[:value]
        else
          logger&.debug "Generating new cache for #{key.inspect}..." if log
          @data[key] = { value: block.call, timestamp: Time.now }
          @data[key][:value]
        end
      end

      if @mutex.locked?
        foo.call
      else
        @mutex.synchronize { foo.call }
      end
    end

    def self.actual?(key, expires_in: DEFAULT_CACHE_EXPIRATION, allow_nil: false)
      @data[key] && (allow_nil || @data[key][:value]) && (expires_in.nil? || Time.now - entry[:timestamp] < expires_in)
    end

    def self.get(key)
      @data[key][:value] if @data[key]
    end

    def self.set(key, value)
      @data[key] = { value: value, timestamp: Time.now }
    end

    def self.clear
      @mutex.synchronize { @data.clear }
    end
  end
end
