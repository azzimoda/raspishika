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
    now Time.now
    day_schedule = day d
    day_schedule[:pairs][n].merge day_schedule.slice(:date, :weekday, :week_type)
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
