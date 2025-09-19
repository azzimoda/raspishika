# frozen_string_literal: true

require 'json'

module Marshal # rubocop:disable Style/Documentation
  def self.deep_clone(obj)
    load dump obj
  end
end

module Raspishika
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
    FIRST_PAIR_START = Time.parse('8:00').freeze
    BIG_BREAK_START = Time.parse('13:05').freeze
    BIG_BREAK_END = Time.parse('13:45').freeze

    class << self
      def from_raw(data)
        raise ArgumentError, 'schedule is nil' if data.nil?
        unless data.is_a? Array
          raise ArgumentError, "Schedule must be an array, but got an #{data.class}: #{data.inspect}"
        end

        new transform data
      end

      private

      def transform(raw_schedule)
        raise ArgumentError, "Schedule is empty or nil: #{raw_schedule.inspect}" if raw_schedule&.empty?

        days_count = raw_schedule.first[:days].count
        days_schedule = Array.new(days_count) { { pairs: [] } }

        raw_schedule.first[:days].each_with_index do |day_info, day_index|
          days_schedule[day_index].merge! day_info.slice(:date, :weekday, :week_type)
        end

        raw_schedule.each do |time_slot|
          time_slot[:days].each_with_index do |day_info, day_index|
            days_schedule[day_index][:pairs] << {
              pair_number: time_slot[:pair_number],
              time_range: time_slot[:time_range]
            }.merge(day_info.slice(:type, :title, :replaced, :content))
          end
        end

        days_schedule
      end
    end

    attr_reader :data

    def initialize(data)
      @data = data
    end

    def ==(other)
      @data == other.data
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

    def day(index = 0)
      Schedule.new [Marshal.deep_clone(@data[index])]
    end

    def pair(index, day_index = 0)
      day_schedule = day.data[day_index]
      day_schedule[:pairs] = [day_schedule[:pairs][index]]
      Schedule.new [day_schedule]
    end

    def now(time: Time.now)
      times = day.data.dig(0, :pairs).map do |pair|
        m = pair[:time_range].match(/^(\d{1,2}:\d{2}).+?(\d{1,2}:\d{2})$/)
        [Time.parse(m[1]) - 10 * 60, Time.parse(m[2])]
      end

      if (index = times.find_index { |t| time.between? t[0], t[1] })
        pair index
      end
    end

    # Returns schedule of today with pairs left after current time. If there is no paris left, returns `nil`.
    def left(from: Time.now)
      if (current_pair = now(time: from)) # On a pair
        current_pair_index = current_pair.data.dig(0, :pairs, 0, :pair_number).to_i - 1
        day.tap { |d| d.data[0][:pairs] = d.data.dig(0, :pairs).slice(current_pair_index..) }
      elsif from <= FIRST_PAIR_START then day # Before the first pair
      elsif from.between? BIG_BREAK_START, BIG_BREAK_END then day # On the big break
      end
    end

    def next_pair
      pair pair[:pair_number] + 1
    end

    def all_empty?
      @data.all? { it[:pairs].all? { it[:type] == :empty } }
    end

    def to_json(*_args)
      @data.to_json
    end

    def from_json(s)
      JSON.parse s
    end

    def format
      return '' if @data.all? { it[:pairs].empty? }

      @data.map do |day|
        if %i[event iga practice vacation].any? { |t| day[:pairs].all? { it[:type] == t } }
          next "📅 #{day[:weekday]}, #{day[:date]}: *#{day.dig :pairs, 0, :content}*"
        end

        pairs = day[:pairs].map { |p| format_pair p }.compact.join "\n\n"
        "📅 #{day[:weekday]}, #{day[:date]}:\n\n#{pairs}"
      end.join("\n\n")
    end

    private

    def format_pair(pair)
      return if pair[:type] == :empty

      classroom = ''
      name =
        case pair[:type]
        when :subject
          classroom = " | #{pair[:content][:classroom]}"
          teacher = shorten_teacher_name pair[:content][:teacher]
          "\n*#{pair[:content][:discipline]}*\n#{teacher}"

        when :exam, :consultation
          classroom = " | #{pair[:content][:classroom]}"
          teacher = shorten_teacher_name pair[:content][:teacher]
          "\n_#{pair[:title]}_\n*#{pair[:content][:discipline]}*\n#{teacher}"

        when :event, :iga, :practice, :vacation
          " — *#{pair[:content]}*"
        end

      "#{pair[:pair_number]} | #{pair[:time_range]}#{classroom}#{name}" if name
    end

    def shorten_teacher_name(name)
      if (parts = name.split).size == 3
        "#{parts.first} #{parts[1][0]}.#{parts[2][0]}."
      else
        name
      end
    end
  end
end
