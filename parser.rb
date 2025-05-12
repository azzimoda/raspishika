require 'nokogiri'
require 'open-uri'
require 'uri'
require 'cgi'
require 'selenium-webdriver'
require 'timeout'

require './image_generator'

class ScheduleParser
  TIMEOUT = 30
  BASE_URL = 'https://mnokol.tyuiu.ru'.freeze

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

    driver = Selenium::WebDriver.for(:chrome, options:)
    begin
      driver.navigate.to(department_url)
      wait = Selenium::WebDriver::Wait.new(timeout: TIMEOUT)

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

  # TODO: Try to use the previous faster algorithm; maybe there is no difference in effectivity.
  def fetch_schedule(group_info)
    logger&.debug "Fetching schedule for group #{group_info}"
    unless group_info[:gr] && group_info[:sid]
      logger&.error "Error: Wrong group data."
      return nil
    end

    url = "https://coworking.tyuiu.ru/shs/all_t/sh.php" \
      "?action=group&union=0&sid=#{group_info[:sid]}&gr=#{group_info[:gr]}&year=#{Time.now.year}&vr=1"
    logger&.info "Fetching schedule from: #{url}"

    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--headless')
    options.add_argument('--disable-gpu')
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-blink-features=AutomationControlled')
    options.add_argument('--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36')

    driver = Selenium::WebDriver.for(:chrome, options:)
    driver.manage.timeouts.page_load = TIMEOUT

    driver.execute_cdp('Network.setExtraHTTPHeaders', headers: {
      'Referer' => 'https://mnokol.tyuiu.ru/',
      'Sec-Fetch-Dest' => 'document',
      'Sec-Fetch-Mode' => 'navigate',
      'Accept-Language' => 'ru-RU,ru;q=0.9'
    })
    driver.get 'https://mnokol.tyuiu.ru/'
    sleep rand(2..5) # Рандомная задержка

    begin
      driver.navigate.to(url)

      driver.action.move_by(0, rand(100..300)).perform
      sleep 0.5

      logger&.info "Waiting for table..."
      sleep 5
      html = driver.page_source
      wait = Selenium::WebDriver::Wait.new(timeout: TIMEOUT)
      _ = wait.until { driver.find_element(id: 'main_table').displayed? }
      html = driver.page_source

      doc = Nokogiri::HTML html
      schedule = parse_schedule_table(doc.at_css('table#main_table')) || "Расписание не найдено"
      ImageGenerator.generate(driver, schedule, **group_info)
      schedule
    rescue Selenium::WebDriver::Error::TimeoutError => e
      logger&.error "Web driver timeout error: #{e.detailed_message}"
      nil
    rescue => e
      logger&.error "Error fetching schedule: #{e.detailed_message}"
      pp e.backtrace
      nil
    ensure
      File.write('.debug/schedule.html', html)
      logger&.debug "Original HTML saved into .debug/schedule.html"
      driver&.quit
    end
  end

  def parse_schedule_table(table)
    unless table
      logger&.warn "Table is nil: #{table.inspect}"
      return nil
    end

    logger&.info "Parsing html table..."

    header_row = table.css('tr').first
    day_headers = header_row.css('td:nth-child(n+3)').map do |header|
      parts = header.children.map { |node| node.text.strip }.reject(&:empty?)
      {
        date: parts[0]&.strip,
        weekday: parts[1]&.strip,
        week_type: parts[2]&.strip
      }
    end

    schedule = []
    table.css('tr:not(:first-child)').each do |row|
      next if row.css('th').any?

      time_cell = row.at_css('td:first-child')
      next unless time_cell

      pair_number = time_cell.text.strip
      time_range = row.at_css('td:nth-child(2)').text.strip

      time_slot = {pair_number:, time_range:, days: []}
      row.css('td:nth-child(n+3)').each_with_index do |day_cell, day_index|
        day_info = day_headers[day_index] || {}
        day_info[:replaced] = day_cell.css('table.zamena').any?

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
      {type: 'event',
       subject: {discipline: day_cell.text.strip}}.merge day_info
    elsif day_cell['class']&.include? 'head_urok_praktik'
      # Practice
      {type: 'subject',
       subject: {discipline: day_cell.text.strip}}.merge day_info
    else
      subject = {
        discipline: day_cell.at_css('.disc')&.text&.strip,
        teacher: day_cell.at_css('.prep')&.text&.strip,
        classroom: day_cell.at_css('.cab')&.text&.strip
      }
      {type: subject[:discipline].empty? ? 'empty' : 'subject',
       subject: subject}.merge day_info
    end
  end
end
