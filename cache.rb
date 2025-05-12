module Cache
  DEFAULT_CACHE_EXPIRATION = ENV["CACHE"]&.empty? ? 0 : ENV["CACHE"].to_i * 60

  @logger = nil # TODO: Configure logger in main.
  @data = {}
  @mutex = Mutex.new

  class << self
    attr_accessor :logger
  end

  def self.fetch(key, expires_in: DEFAULT_CACHE_EXPIRATION, allow_nil: false, &block)
    # TODO: Rewrite logger calls after I confuge logger for the module in main.
    logger.debug "Fetching cache for: #{key.inspect}"
    @mutex.synchronize do
      if DEFAULT_CACHE_EXPIRATION.zero?
        logger.warn "Skipping caching because of environment configuration"
        return block.call
      end

      entry = @data[key]
      if entry && (allow_nil || entry[:value]) && (expires_in.nil? || Time.now - entry[:timestamp] < expires_in)
        logger.debug "Returning existing cache"
        entry[:value]
      else
        logger.debug "Generating new cache"
        @data[key] = { value: block.call, timestamp: Time.now }
        @data[key][:value]
      end
    end
  end

  def self.clear
    @mutex.synchronize { @data.clear }
  end

  # TODO: Maybe save cache for situations when I need to just restart bot for less than 5 minutes.
end
