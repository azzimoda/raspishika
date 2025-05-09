require 'json'

class Schedule
  # TODO: Maybe I should implement a field structure to make it more strict.
  def initialize hash
    @hash = hash
  end

  def week
    transform_schedule_to_days @hash
  end

  def day n
    week[n]
  end

  def pair n, d=0
    day_schedule = day d
    day_schedule[:pairs][n].merge day_schedule.slice(:date, :weekday, :week_type, :replaced)
  end

  def now
    day_schedule = day 0
    times = day_schedule[:pairs].map do |pair|
      m = p pair[:time_range].match %r(^(\d{1,2}:\d{2}).+?(\d{1,2}:\d{2})$)
      p [Time.parse(m[1]), Time.parse(m[2])]
    end
    time = p Time.now
    if (index = times.find_index { |t| t[0] <= time && time <= t[1] })
      pair index
    end
  end

  def next_pair
    pair pair[:pair_number] + 1
  end

  def to_json
    @hash.to_json
  end

  def from_json s
    JSON.parse s
  end
end
