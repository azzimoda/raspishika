require 'nokogiri'
require 'open-uri'
require 'uri'
require 'cgi'
require 'selenium-webdriver'
require 'timeout'

BASE_URL = 'https://mnokol.tyuiu.ru'.freeze

WEEKDAY_SHORTS = {
  'понедельник': 'пн',
  'вторник': 'вт',
  'среда': 'ср',
  'четверг': 'чт',
  'пятница': 'пт',
  'суббота': 'сб',
  'воскресенье': 'вс' # it's useless btw
}.freeze

class ScheduleParser
  def initialize logger: nil
    @logger = logger
    @departments = {}
    @group_schedules = {}
    @user_context = {}
  end
  attr_accessor :logger
  attr_reader :user_context

  def fetch_departments
    logger&.info "Fetching departaments..."

    url = "#{BASE_URL}/site/index.php?option=com_content&view=article&id=1582&Itemid=247"
    doc = Nokogiri::HTML(URI.open(url))

    doc.css('ul.mod-menu li.col-lg.col-md-6 a').each do |link| # Add classes .col-lg and .col-md-6 to li
      department_name = link.text.strip
      department_url = link['href'].gsub('&amp;', '&')
      @departments[department_name] = "#{BASE_URL}#{department_url}"
    end

    logger&.debug @departments

    @departments
  rescue => e
    logger&.error "Error fetching departments: #{e.message}"
    {}
  end

  def fetch_groups(department_url)
    logger&.info "Fetching groups for #{department_url}"
    return {} if department_url.nil? || department_url.empty?

    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--headless')
    options.add_argument('--disable-gpu')
    options.add_argument('--no-sandbox')

    driver = Selenium::WebDriver.for(:chrome, options: options)
    begin
      driver.navigate.to(department_url)
      wait = Selenium::WebDriver::Wait.new(timeout: 20)

      iframe = wait.until { driver.find_element(:css, 'div.com-content-article__body iframe') }
      driver.switch_to.frame(iframe)

      select = wait.until { driver.find_element(:id, 'groups') }
      groups = {}

      select.find_elements(:tag_name, 'option').each do |option|
        next if option['value'] == '0'
        groups[option.text.strip] = {
          gr: option['value'],
          sid: option.attribute('sid')
        }
      end

      groups
    rescue => e
      logger&.error "Error fetching groups: #{e.message}"
      {}
    ensure
      driver&.quit
    end
  end

  def fetch_schedule(group_info)
    logger&.debug "Fetching schedule for group #{group_info}"
    return "Ошибка: неверные данные группы" unless group_info[:gr] && group_info[:sid]

    url = "https://coworking.tyuiu.ru/shs/all_t/sh.php" \
      "?action=group&union=0&sid=#{group_info[:sid]}&gr=#{group_info[:gr]}&year=#{Time.now.year}&vr=1"
    logger&.info "Fetching schedule from: #{url}"

    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--headless')
    options.add_argument('--disable-gpu')
    options.add_argument('--no-sandbox')

    driver = Selenium::WebDriver.for(:chrome, options: options)
    begin
      driver.navigate.to(url)
      wait = Selenium::WebDriver::Wait.new(timeout: 60)

      logger&.info "Waiting for table..."
      _ = wait.until { driver.find_element(id: 'main_table') }
      html = driver.page_source
      File.write('schedule.html', html)

      doc = Nokogiri::HTML html

      parse_schedule_table(doc.at_css('table#main_table')) || "Расписание не найдено"
    rescue => e
      logger&.error "Error fetching schedule: #{e.message}"
      "Не удалось загрузить расписание"
    ensure
      driver&.quit
    end
  end

  def parse_schedule_table(table)
    return [] unless table
  
    # First, extract the day headers to get dates and day names
    header_row = table.css('tr').first
    day_headers = header_row.css('td:nth-child(n+3)').map do |header|
      # parts = header.text.strip.split("\n")
      parts = header.children.map { |node| node.text.strip }.reject(&:empty?)
      logger.debug "Date parts: #{parts.join', '}"
      {
        date: parts[0]&.strip,
        weekday: parts[1]&.strip,
        week_type: parts[2]&.strip
      }
    end
  
    schedule = []
    table.css('tr:not(:first-child)').each do |row|
      next if row.css('th').any? # skip header rows if any
  
      time_cell = row.at_css('td:first-child')
      next unless time_cell # skip if no time cell
  
      pair_number = time_cell.text.strip
      time_range = row.at_css('td:nth-child(2)').text.strip
  
      time_slot = {pair_number: pair_number, time_range: time_range, days: []}
      row.css('td:nth-child(n+3)').each_with_index do |day_cell, day_index|
        day_info = day_headers[day_index] || {}

        # Check for event cells (like holidays)
        time_slot[:days] << parse_day_entry(day_cell, day_info)
      end
      schedule << time_slot
    end
    schedule
  end

  private

  def parse_day_entry day_cell, day_info
    if day_cell['class']&.include? 'event'
      # Event
      {date: day_info[:date],
       weekday: day_info[:weekday],
       week_type: day_info[:week_type],
       type: 'event',
       subject: day_cell.text.strip}
    elsif day_cell['class']&.include? 'head_urok_praktik'
      # Practice
      {date: day_info[:date],
        weekday: day_info[:weekday],
        week_type: day_info[:week_type],
        type: 'subject',
        subjects: [{discipline: day_cell.text.strip, teacher: nil, classroom: nil}]}
    else
      # Regular pair
      # TODO: Get rid of array, there can be only one pair
      subjects = day_cell.css('div.pair').map do |pair|
        {discipline: pair.at_css('.disc')&.text&.strip,
          teacher: pair.at_css('.prep')&.text&.strip,
          classroom: pair.at_css('.cab')&.text&.strip}
      end

      if subjects.empty?
        discipline = day_cell.at_css('.disc')&.text&.strip
        teacher = day_cell.at_css('.prep')&.text&.strip
        classroom = day_cell.at_css('.cab')&.text&.strip

        if discipline || teacher || classroom
          subjects = [{ discipline: discipline, teacher: teacher, classroom: classroom }]
        end
      end

      {date: day_info[:date],
        weekday: day_info[:weekday],
        week_type: day_info[:week_type],
        type: subjects.any? ? 'subject' : 'empty',
        subjects: subjects}
    end
  end
end

def transform_schedule_to_days(schedule)
  return [] if schedule.empty?

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
    }.merge(day_info.slice(:type, :subject, :subjects))
    end
  end

  days_schedule
end

def format_schedule_days(schedule)
  schedule.map do |day|
    day_head = "#{day[:weekday][0,2]}, #{day[:date]} (#{day[:week_type]} неделя)"
    pairs = day[:pairs].map.with_index do |pair, index|
      name = if pair[:type] == 'subject'
        pair[:subjects][0].values.join ' '
      elsif pair[:type] == 'event'
        pair[:subject]
      end
      "#{pair[:pair_number]} — #{pair[:time_range]} — #{name}"
    end

    "#{day_head}:\n" + pairs.join("\n")
  end.join("\n")
end

def pp_schedule(schedule)
  schedule.each do |time_slot|
    puts "Time: #{time_slot[:time_range]}"
    time_slot[:days].each do |day_entry|
      puts "\tDate: #{day_entry[:date]}, Day: #{day_entry[:weekday]}, Week Type: #{day_entry[:week_type]}"
      if day_entry[:type] == 'subject'
        day_entry[:subjects].each do |subject|
          puts "\t\tSubject: #{subject[:discipline]}, Teacher: #{subject[:teacher]}, Classroom: #{subject[:classroom]}"
        end
      elsif day_entry[:type] == 'empty'
        puts "\t\tEmpty"
      elsif day_entry[:type] == 'event'
        puts "\t\tEvent: #{day_entry[:subject]}"
      end
      puts
    end
  end
end

def pp_schedule_days(schedule)
  puts format_schedule_days schedule
end
