require 'nokogiri'
require 'open-uri'
require 'uri'
require 'cgi'
require 'playwright' # NOTE: Playwright is synchronouse YET
require 'timeout'

require_relative 'image_generator'

module Raspishika
  class ScheduleParser
    TIMEOUT = 30
    MAX_RETRIES = 3
    BASE_URL = 'https://mnokol.tyuiu.ru'.freeze
  
    def initialize(logger: nil)
      @logger = logger
      @thread = nil
      @browser = nil
      @ready = false
      @mutex = Mutex.new
    end
    attr_accessor :logger, :ready
  
    def ready?
      @ready
    end
  
    def initialize_browser_thread
      logger&.info "Initializing browser thread..."
      @thread = Thread.new do
        Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
          @browser = playwright.chromium.launch(headless: true, timeout: TIMEOUT * 1000)
          logger&.info "Browser is ready"
          @ready = true
          sleep 1 while @browser.connected?
        end
        logger&.info "Browser thread is stopped."
      end
    end
  
    def stop_browser_thread
      logger&.info "Stopping browser thread..."
      @browser&.close
      @thread&.join
    end
  
    def use_browser(&block)
      @mutex.synchronize { block.call @browser }
    end
  
    def fetch_departments
      logger&.info "Fetching departments..."
  
      url = "#{BASE_URL}/site/index.php?option=com_content&view=article&id=1582&Itemid=247"
      doc = Nokogiri::HTML(URI.open(url))
  
      doc.css('ul.mod-menu li.col-lg.col-md-6 a').map do |link|
        department_name = link.text.strip
        department_url = link['href'].gsub('&amp;', '&')
        [department_name, "#{BASE_URL}#{department_url}"]
      end.to_h.filter! do |name, url|
        name.downcase.then { it.include?('отделение') || it == 'заочное обучение' }
      end.tap { logger&.debug it }
    rescue => e
      logger&.error "Unhandled error in `#fetch_departments`: #{e.detailed_message}"
      nil
    end
  
    def fetch_groups(department_url)
      if department_url.nil? || department_url.empty?
        raise ArgumentError, "department_url is `nil` or empty: #{department_url.inspect}"
      end
  
      logger&.info "Fetching groups for #{department_url}"
  
      groups = {}
      use_browser do |browser|
        page = browser.new_page
        options = try_timeout do
          page.goto(department_url, timeout: TIMEOUT * 1000)
  
          iframe = page.wait_for_selector(
            'div.com-content-article__body iframe',
            timeout: TIMEOUT * 1000
          )
          page = iframe.content_frame
  
          select = page.wait_for_selector('#groups', timeout: TIMEOUT * 1000)
          raise "Failed to find groups selector" if select.nil?
  
          page.eval_on_selector_all(
            '#groups option',
            'els => els.map(el => ({ text: el.textContent.trim(), value: el.value, sid: el.getAttribute("sid") }))'
          )
        end
  
        options.each do |opt|
          next if opt['value'] == '0'
          groups[opt['text']] = { gr: opt['value'], sid: opt['sid'] }
        end
      end
  
      groups
    rescue => e
      logger&.error "Unhandled error in `#fetch_groups`: #{e.detailed_message}"
      nil
    end
  
    def fetch_schedule(group_info)
      logger&.info "Fetching schedule for #{group_info}"
      unless group_info[:gr] && group_info[:sid]
        logger&.error "Wrong group data"
        return nil
      end
  
      base_url = "https://coworking.tyuiu.ru/shs/all_t/sh#{group_info[:zaochnoe] ? 'z' : ''}.php"
      url = "#{base_url}?action=group&union=0&sid=#{group_info[:sid]}&gr=#{group_info[:gr]}&year=#{Time.now.year}&vr=1"
      logger&.debug "URL: #{url}"
  
      html = nil
      use_browser do |browser|
        page = browser.new_page
  
          page.set_extra_http_headers(
          'Referer' => 'https://mnokol.tyuiu.ru/',
          'Accept-Language' => 'ru-RU,ru;q=0.9',
          'Sec-Fetch-Dest' => 'document',
          'Sec-Fetch-Mode' => 'navigate'
        )
  
        page.goto('https://mnokol.tyuiu.ru/', timeout: TIMEOUT * 1000)
        sleep 1
  
        html = nil
        try_timeout do
          page.goto(url, timeout: TIMEOUT * 1000)
  
          page.mouse.move(0, rand(100..300))
          sleep 0.5
  
          logger&.debug "Waiting for table..."
          html = page.content
          page.wait_for_selector('#main_table', timeout: TIMEOUT * 1000)
          html = page.content
        end
  
        doc = Nokogiri::HTML html
        schedule = parse_schedule_table(doc.at_css('table#main_table')) || "Расписание не найдено"
        raise "Failed to find table#main_table." unless schedule
  
        ImageGenerator.generate(page, schedule, **group_info)
        schedule
      rescue Playwright::TimeoutError => e
        logger&.error "Timeout error while parsing schedule: #{e.detailed_message}"
        logger&.debug e.backtrace.join"\n"
        nil
      ensure
        debug_dir = File.join('data', 'debug')
        Dir.mkdir(debug_dir) unless Dir.exist?(debug_dir)
        # Saving original HTML into data/debug/schedule.html for debug
        File.write(File.join(debug_dir, 'schedule.html'), html)
      end
    end
  
    def try_timeout(times: MAX_RETRIES, &block)
      retries = times
      delay = 1
      begin
        return block.call
      rescue => e
        retries -= 1
        if retries > 0
          logger&.warn "Failed to load page, retrying... (#{retries} retries left)"
          sleep delay
          delay *= 2
          retry
        else
          logger&.error "Failed to load page after #{times} retries"
          raise e
        end
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
      table.css('tr.para_num:not(:first-child)').each do |row|
        next if row.css('th').any?
  
        time_cell = row.at_css('td:first-child')
        next unless time_cell
  
        pair_number = time_cell.text.strip
        time_range = row.at_css('td:nth-child(2)')
        if time_range.nil?
          logger&.error "Failed to parse time range."
          return nil
        end
        time_range = time_range.text.strip
  
        time_slot = {pair_number:, time_range:, days: []}
        row.css('td:nth-child(n+3)').each_with_index do |day_cell, day_index|
          day_info = day_headers[day_index] || {}
          day_info[:replaced] = day_cell.css('table.zamena').any?
          day_info[:consultation] = day_cell.css('table.consultation').any?
          time_slot[:days] << parse_day_entry(day_cell, day_info)
        end
        schedule << time_slot
      end
      schedule
    end
  
    private
  
    def parse_day_entry day_cell, day_info
      day_info.merge case
      when day_cell['class']&.include?('head_urok_block') && day_cell.text.strip.downcase == 'нет занятий'
        {type: :empty}
      when day_cell.text.downcase.include?('снято') || day_cell.at_css('.disc')&.text&.strip&.empty?
        {type: :empty}
      when day_cell['class']&.include?('head_urok_iga')
        {type: :iga, content: day_cell.text.strip}
      when day_cell['class']&.include?('event')
        {type: :event, content: day_cell.text.strip}
      when day_cell['class']&.include?('head_urok_praktik')
        {type: :practice, content: day_cell.text.strip}
      when day_cell['class']&.include?('head_urok_session')
        {type: :session, content: day_cell.text.strip}
      when day_cell['class']&.include?('head_urok_kanik')
        {type: :vacation, content: day_cell.text.strip}
      when (day_cell.css('table.zachet').any? || day_cell.css('table.difzachet').any? ||
            day_cell.css('table.ekzamen').any?)
        {type: :exam, title: day_cell.at_css('.head_ekz').text.strip, content: {
          discipline: day_cell.at_css('.disc')&.text&.strip,
          teacher: day_cell.at_css('.prep')&.text&.strip,
          classroom: day_cell.at_css('.cab')&.text&.strip
        }}
      when day_info[:consultation]
        {type: :consultation, title: day_cell.at_css('.head_ekz').text.strip, content: {
          discipline: day_cell.at_css('.disc')&.text&.strip,
          teacher: day_cell.at_css('.prep')&.text&.strip,
          classroom: day_cell.at_css('.cab')&.text&.strip
        }}
      else
        {type: :subject, content: {
          discipline: day_cell.at_css('.disc')&.text&.strip,
          teacher: day_cell.at_css('.prep')&.text&.strip,
          classroom: day_cell.at_css('.cab')&.text&.strip
        }}
      end
    end
  end
end
