module Cache
  DEFAULT_CACHE_EXPIRATION = ENV["CACHE"]&.empty? ? 0 : ENV["CACHE"].to_i * 60

  @logger = nil
  @data = {}
  @mutex = Mutex.new

  class << self
    attr_accessor :logger
  end

  def self.fetch(key, expires_in: DEFAULT_CACHE_EXPIRATION, allow_nil: false, log: true, &block)
    logger&.debug "Fetching cache for: #{key.inspect}" if log
    if DEFAULT_CACHE_EXPIRATION.zero?
      logger&.warn "Skipping caching because of environment configuration" if log
      return block.call
    end

    @mutex.synchronize do
      entry = @data[key]
      if entry && (allow_nil || entry[:value]) && (expires_in.nil? || Time.now - entry[:timestamp] < expires_in)
        logger&.debug "Returning existing cache" if log
        entry[:value]
      else
        logger&.debug "Generating new cache" if log
        @data[key] = { value: block.call, timestamp: Time.now }
        @data[key][:value]
      end
    end
  end

  def self.clear
    @mutex.synchronize { @data.clear }
  end
end
