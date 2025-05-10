module Cache
  @data = {}
  @mutex = Mutex.new

  def self.fetch(key, expires_in: nil, allow_nil: false, &block)
    $logger.debug "Fetching cache for: #{key.inspect}"
    @mutex.synchronize do
      entry = @data[key]
      if entry && (allow_nil || entry[:value]) && (expires_in.nil? || Time.now - entry[:timestamp] < expires_in)
        $logger.debug "Returning existing cache"
        entry[:value]
      else
        $logger.debug "Generating new cache"
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
