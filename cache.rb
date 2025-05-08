module Cache
  @data = {}
  @mutex = Mutex.new

  def self.fetch(key, expires_in: nil, &block)
    @mutex.synchronize do
      entry = @data[key]
      if entry && (expires_in.nil? || Time.now - entry[:timestamp] < expires_in)
        entry[:value]
      else
        @data[key] = { value: block.call, timestamp: Time.now }
      end
    end
  end

  def self.clear
    @mutex.synchronize { @data.clear }
  end
end
