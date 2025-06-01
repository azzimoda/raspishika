require 'json'

module Marshal
  def self.deep_clone obj
    load dump obj
  end
end

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

    def transform raw_schedule
      if raw_schedule&.empty?
        raise ArgumentError, "Schedule is empty or nil: #{raw_schedule.inspect}"
      end

      days_count = raw_schedule.first[:days].count
      days_schedule = Array.new(days_count) { { pairs: [] } }

      raw_schedule.first[:days].each_with_index do |day_info, day_index|
        days_schedule[day_index].merge! day_info.slice(:date, :weekday, :week_type)
      end

      raw_schedule.each do |time_slot|
        time_slot[:days].each_with_index do |day_info, day_index|
          days_schedule[day_index][:pairs] << {
            pair_number: time_slot[:pair_number],
            time_range: time_slot[:time_range],
          }.merge(day_info.slice(:type, :title, :replaced, :content))
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
    Schedule.new Marshal.deep_clone @data
  end

  def days(*args)
    if args.size == 1 && args[0].is_a?(Integer)
      day args[0]
    else
      Schedule.new Marshal.deep_clone @data.slice(*args)
    end
  end

  def day n=0
    Schedule.new [Marshal.deep_clone(@data[n])]
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
      current_day = day
      slice = ((current_pair.data[0][:pairs][0][:pair_number].to_i - 1)..)
      current_day.tap { |d| d.data[0][:pairs] = current_day.data[0][:pairs].slice slice }
    elsif from <= Time.parse('8:00')
      day # Before the first pair
    elsif from.between?(Time.parse('13:05'), Time.parse('13:45'))
      day # On the big break
    end # else nil
  end

  def next_pair
    pair pair[:pair_number] + 1
  end

  def all_empty?
    @data.all? { it[:pairs].all? { it[:type] == :empty } }
  end

  def to_json
    @data.to_json
  end

  def from_json s
    JSON.parse s
  end

  def format
    return '' if @data.all? { it[:pairs].empty? }

    @data.map do |day|
      if [:event, :iga, :practice].any? { |type| day[:pairs].all? { it[:type] == type } }
        next "📅 #{day[:weekday]}, #{day[:date]}: *#{day[:pairs][0][:content]}*"
      end

      pairs = day[:pairs].map do |pair|
        next if pair[:type] == :empty

        classroom = ""
        name = case pair[:type]
        when :subject
          classroom = " | #{pair[:content][:classroom]}"
          teacher = if (parts = pair[:content][:teacher].split).size == 3
            "#{parts.first} #{parts[1][0]}.#{parts[2][0]}."
          else
            pair[:content][:teacher]
          end
          "\n*#{pair[:content][:discipline]}*\n#{teacher}"

        when :exam, :consultation
          classroom = " | #{pair[:content][:classroom]}"
          teacher = if (parts = pair[:content][:teacher].split).size == 3
            "#{parts.first} #{parts[1][0]}.#{parts[2][0]}."
          else
            pair[:content][:teacher]
          end
          "\n_#{pair[:title]}_\n*#{pair[:content][:discipline]}*\n#{teacher}"

        when :event, :iga, :practice
          " — *#{pair[:content]}*"
        end

        "#{pair[:pair_number]} | #{pair[:time_range]}#{classroom}#{name}" if name
      end.compact.join "\n\n"

      "📅 #{day[:weekday]}, #{day[:date]}:\n\n#{pairs}"
    end.join("\n\n")
  end
end
