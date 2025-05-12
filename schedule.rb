require 'json'

class Schedule
  WEEKDAY_SHORTS = {
    'понедельник' => 'пн',
    'вторник' => 'вт',
    'среда' => 'ср',
    'четверг' => 'чт',
    'пятница' => 'пт',
    'суббота' => 'сб',
    'воскресенье' => 'вс' # it's useless btw
  }.freeze

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
        }.merge(day_info.slice(:type, :subject, :replaced, :date, :weekday))
        end
      end
  
      days_schedule
    end  
  end

  # TODO: Maybe I should implement structure to make it more strict.
  def initialize data
    @data = data
  end

  def == other
    @data == other.data
  end

  def data
    @data
  end

  def deep_clone
    Schedule.new Marshal.load Marshal.dump @data
  end

  def days(*args)
    Schedule.new Marshal.load Marshal.dump @data.slice(*args)
  end

  def day n=0
    Schedule.new [Marshal.load(Marshal.dump(@data[n]))]
  end

  def pair n, d=0
    day_schedule = day.data[d]
    day_schedule[:pairs] = [day_schedule[:pairs][n]]
    Schedule.new [day_schedule]
  end

  def now(time: Time.now)
    times = day.data[0][:pairs].map do |pair|
      m = pair[:time_range].match %r(^(\d{1,2}:\d{2}).+?(\d{1,2}:\d{2})$)
      [Time.parse(m[1]) - 10*60, Time.parse(m[2])]
    end

    if (index = times.find_index { |t| t[0] <= time && time <= t[1] })
      pair index
    end
  end

  # Returns schedule of today with pairs left after current time. If there is no paris left, returns `nil`.
  # @param from [Time]
  # @return [Schedule, NilClass]
  def left(from: Time.now)
    if (current_pair = now(time: from))
      # On a pair
      puts "On a pair"
      pp current_pair
      current_day = day
      slice = ((current_pair.data[0][:pairs][0][:pair_number].to_i - 1)..)
      current_day.tap { |d| d.data[0][:pairs] = current_day.data[0][:pairs].slice slice }
    elsif from <= Time.parse('8:00')
      # Before the first pair
      puts 'Before the first pair'
      day
    elsif from.between?(Time.parse('13:05'), Time.parse('13:45')) # Time.parse('13:05') <= from && from <= Time.parse('13:45')
      # On the big break
      puts 'On the big break'
      day
    else
      # Nothing
      puts 'Nothing'
      nil
    end
  end

  def next_pair
    pair pair[:pair_number] + 1
  end

  def to_json
    @data.to_json
  end

  def from_json s
    JSON.parse s
  end

  def format
    @data.map do |day|
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
