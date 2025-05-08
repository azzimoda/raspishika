module DebugCommands
  def self.fetch_schedule(bot, parser, logger, sid: 28703, gr: 427)
    logger.debug "Fetching schedule for sid=#{sid}, gr=#{gr}"
    schedule = parser.fetch_schedule({sid: sid, gr: gr})
    format_schedule_days transform_schedule_to_days schedule
  end
end
