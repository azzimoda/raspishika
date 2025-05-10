require 'json'

class Schedule
  class << self
    def from_raw data
      raise ArgumentError, "schedule is nil" if data.nil?
      unless data.is_a? Array
        raise ArgumentError, "Schedule must be an array, but got an #{data.class}: #{data.inspect}"
      end

      new transform data
    end
  
    private
  
    def transform schedule
      return [] if schedule&.empty?
    
      # Initialize array with one entry per day (based on first time slot's days count)
      days_count = schedule.first[:days].count
      days_schedule = Array.new(days_count) { { pairs: [] } }
  
      schedule[0][:days].each_with_index do |day_info, day_index|
        days_schedule[day_index].merge! day_info.slice(:date, :weekday, :week_type)
      end
  
      schedule.each do |time_slot|
        time_slot[:days].each_with_index do |day_info, day_index|
          # Create a time slot entry for this day
          days_schedule[day_index][:pairs] << {
            pair_number: time_slot[:pair_number],
            time_range: time_slot[:time_range],
        }.merge(day_info.slice(:type, :subject, :replaced, :weekday))
        end
      end
  
      days_schedule
    end  
  end

  # TODO: Maybe I should implement structure to make it more strict.
  def initialize hash
    @hash = hash
  end

  def data
    @hash
  end

  def days(*args)
    Schedule.new Marshal.load Marshal.dump @hash.slice(*args)
  end

  def day n=0
    Schedule.new [Marshal.load(Marshal.dump(@hash[n]))]
  end

  def pair n, d=0
    day_schedule = day.data[d]
    day_schedule[:pairs] = [day_schedule[:pairs][n].merge(day_schedule.slice(:date, :weekday, :week_type, :replaced))]
    Schedule.new [day_schedule]
  end

  def now
    day_schedule = day
    times = day_schedule.data[0][:pairs].map do |pair|
      m = pair[:time_range].match %r(^(\d{1,2}:\d{2}).+?(\d{1,2}:\d{2})$)
      [Time.parse(m[1]) - 10*60, Time.parse(m[2])]
    end
    time = Time.now
    if (index = times.find_index { |t| t[0] <= time && time <= t[1] })
      pair index
    end
  end

  def left
    if (current_pair = now)
      current_day = day
      slice = ((current_pair.data[0][:pairs][0][:pair_number].to_i - 1)..)
      current_day.data[0][:pairs] = current_day.data[0][:pairs].slice slice
      current_day
    elsif Time.now <= Time.parse('8:00')
      day
    end # else nil
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

  def format
    @hash.map do |day|
      weekday = WEEKDAY_SHORTS[day[:weekday].downcase].upcase
      day_head = "#{weekday}, #{day[:date]} (#{day[:week_type]} неделя)"
      pairs = day[:pairs].map.with_index do |pair, index|
        next if pair[:subject][:discipline]&.strip&.empty?

        classroom = ""
        name = if pair[:type] == 'subject'
          classroom = " — #{pair[:subject][:classroom]}"
          teacher = if (parts = pair[:subject][:teacher].split).size == 3
            "#{parts.first} #{parts[1][0]}.#{parts[2][0]}."
          else
            pair[:subject][:teacher]
          end
          "\n  #{pair[:subject][:discipline]}, #{teacher}"
        elsif pair[:type] == 'event'
          " — #{pair[:subject][:discipline]}"
        end

        "  #{pair[:pair_number]} — #{pair[:time_range]}#{classroom}#{name}"
      end.compact

      "#{day_head}:\n" + pairs.join("\n")
    end.join("\n\n")
  end
end
