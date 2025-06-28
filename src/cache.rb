module Raspishika
  module Cache
    DEFAULT_CACHE_EXPIRATION = 10*60 # 10 minutes
    @logger = nil
    @data = {}
    @mutex = Mutex.new

    class << self
      attr_accessor :logger
    end

    def self.fetch(key, expires_in: DEFAULT_CACHE_EXPIRATION, allow_nil: false, log: true, &block)
      if DEFAULT_CACHE_EXPIRATION.zero?
        logger&.debug "Skipping caching for #{key.inspect} because of environment configuration..." if log
        return block.call
      end

      @mutex.synchronize do
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
    end

    def self.clear
      @mutex.synchronize { @data.clear }
    end
  end
end
