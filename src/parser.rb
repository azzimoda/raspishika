require 'nokogiri'
require 'open-uri'
require 'uri'
require 'cgi'
require 'playwright' # NOTE: Playwright is synchronouse YET
require 'timeout'
require 'prettyprint'

require_relative 'image_generator'

module Raspishika
  class ScheduleParser
    TIMEOUT = 15
    MAX_RETRIES = 3
    LONG_CACHE_TIME = 30*24*60*60 # 1 month
    BASE_URL = 'https://mnokol.tyuiu.ru'.freeze

    def initialize(logger: Logger.new($stdout))
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
      Cache.fetch :departments, expires_in: LONG_CACHE_TIME, file: true do
        logger.info "Fetching departments..."

        url = "#{BASE_URL}/site/index.php?option=com_content&view=article&id=1582&Itemid=247"
        doc = Nokogiri::HTML(URI.open(url))

        deps = doc.css('ul.mod-menu li.col-lg.col-md-6 a').map do |link|
          department_name = link.text.strip
          department_url = link['href'].gsub('&amp;', '&')
          [department_name, "#{BASE_URL}#{department_url}"]
        end.to_h
        deps.select! do |name, url|
          name.downcase.then { it.include?('отделение') || it == 'заочное обучение' }
        end
        deps.tap { logger.debug it }
      end
    rescue => e
      logger.error "Unhandled error in `#fetch_departments`: #{e.detailed_message}"
      logger.error "Backtrace:\n#{e.backtrace.join("\n")}"
      nil
    end

    def fetch_all_groups(departments_urls)
      logger.info "Fetching all groups..."
      Cache.fetch :groups, expires_in: LONG_CACHE_TIME, file: true do
        departments_urls.each_with_object({}) { |(name, url), groups| groups[name] = fetch_groups url, name }
      end
    end

    def fetch_groups(department_url, department_name)
      if department_url.nil? || department_url.empty?
        raise ArgumentError, "department_url is `nil` or empty: #{department_url.inspect}"
      end

      Cache.fetch :"groups_#{department_name}", expires_in: LONG_CACHE_TIME, file: true do
        logger.info "Fetching groups for #{department_url}"

        groups = {}
        use_browser do |browser|
          page = browser.new_page
          options = try_timeout do
            page.goto(department_url, timeout: TIMEOUT * 1000)

            iframe = page.wait_for_selector(
              'div.com-content-article__body iframe',
              timeout: TIMEOUT * 1000
            )
            frame = iframe.content_frame

            select = frame.wait_for_selector('#groups', timeout: TIMEOUT * 1000)
            raise "Failed to find groups selector" if select.nil?

            frame.eval_on_selector_all(
              '#groups option',
              'els => els.map(el => ({ text: el.textContent.trim(), value: el.value, sid: el.getAttribute("sid") }))'
            )
          end
          page.close

          options.each do |opt|
            next if opt['value'] == '0'
            groups[opt['text']] = { gr: opt['value'], sid: opt['sid'] }
          end
        end

        groups
      end
    rescue => e
      logger.error "Unhandled error in `#fetch_groups`: #{e.detailed_message}"
      logger.error "Backtrace:\n#{e.backtrace.join("\n")}"
      nil
    end
  
    def fetch_schedule(group_info)
      logger.info "Fetching schedule for #{group_info}"
      unless group_info[:gr] && group_info[:sid]
        logger.error "Wrong group data"
        return nil
      end

      if Cache.actual? :"schedule_#{group_info[:sid]}_#{group_info[:gr]}"
        return Cache.get :"schedule_#{group_info[:sid]}_#{group_info[:gr]}"
      end

      base_url = "https://coworking.tyuiu.ru/shs/all_t/sh#{group_info[:zaochnoe] ? 'z' : ''}.php"
      url = "#{base_url}?action=group&union=0&sid=#{group_info[:sid]}&gr=#{group_info[:gr]}&year=#{Time.now.year}&vr=1"
      logger.debug "URL: #{url}"

      # First try
      html, schedule = try_get_schedule url, group_info, times: 1, raise_on_failure: false
      return schedule if html && schedule

      logger.warn "Failed to load page, trying to update department ID..."

      new_group_info = update_department_id group_info
      group_info = group_info.merge new_group_info
      url = "#{base_url}?action=group&union=0&sid=#{new_group_info[:sid]}&gr=#{new_group_info[:gr]}&year=#{Time.now.year}&vr=1"
      logger.debug "URL: #{url}"

      # Second try with updated department ID
      html, schedule = try_get_schedule url, group_info
      return schedule
    rescue Playwright::TimeoutError => e
      logger.error "Timeout error while parsing schedule: #{e.detailed_message}"
      logger.debug e.backtrace.join"\n"
      nil
    ensure
      debug_dir = File.join('data', 'debug')
      Dir.mkdir(debug_dir) unless Dir.exist?(debug_dir)
      # Saving original HTML into data/debug/schedule.html for debug
      File.write(File.join(debug_dir, 'schedule.html'), html)
    end

    def try_fetch_schedule(url, group_info, **kwargs)
      html, schedule = nil
      use_browser do |browser|
        page = browser.new_page
        try_timeout(**kwargs) do
          page.goto('https://mnokol.tyuiu.ru/', timeout: TIMEOUT * 1000)
          sleep 1
          headers = generate_headers
          logger.debug "HEADERS: #{headers.pretty_inspect}"
          page.set_extra_http_headers(**headers)
          html = nil
          page.goto(url, timeout: TIMEOUT * 1000)
          html = page.content
          sleep 0.5

          logger.debug "Waiting for table..."
          page.wait_for_selector('#main_table', timeout: TIMEOUT * 1000)
          html = page.content
        end

        unless html
          page.close
          return nil if kwargs[:raise_on_failure] == false
          raise "Failed to load page after #{MAX_RETRIES} retries"
        end

        doc = Nokogiri::HTML html
        schedule = parse_schedule_table(doc.at_css('table#main_table'))
        unless schedule
          page.close
          return nil if kwargs[:raise_on_failure] == false
          raise "Failed to find table#main_table."
        end

        ImageGenerator.generate(page, schedule, **group_info)
        page.close
      end
      Cache.set :"schedule_#{group_info[:sid]}_#{group_info[:gr]}", schedule
      return html, schedule
    end

    def generate_headers
      platforms = ["Windows NT #{%w[6.1 6.2 6.3 10.0].sample}; Win64; x64",
                   "Macintosh; #{%w[Intel ARM].sample} Mac OS X 10_15_7",
                   "X11; Linux #{%w[x86_64 i686 armv71].sample}", 'Linux; Android 14; SM-S901B',
                   'iPhone; CPU iPhone OS 17_5 like Mac OS X', 'iPad; CPU OS 17_5 like Mac OS X'].freeze
      {
        'User-Agent' =>
          "Mozilla/5.0 (#{platforms.sample}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/#{rand(129..130)}.0.0.0 Safari/537.36",
        'Referer' => 'https://coworking.tyuiu.ru/shs/all_t/',
        'Accept-Language' => "#{%w[ru-RU,ru en-US,en].sample};q=0.#{rand(5..9)}",
      }.tap do |a|
        {'Sec-Fetch-Dest' => 'document', 'Sec-Fetch-Mode' => 'navigate', 'Connection' => 'keep-alive'}
          .each { |k, v| a[k] = v if rand(2).zero? }
      end
    end

    def update_department_id(group_info)
      # Update department ID for all users in the group.
      deps = fetch_departments
      department_url = deps[group_info[:department]]
      return logger.error "Failed department url by name #{group_info[:department].inspect}" unless department_url

      groups = fetch_groups(department_url, group_info[:department])
      return unless groups

      new_group_info = groups[group_info[:group]]
      return logger.error "Failed to group info by group name #{group_info[:group].inspect}" unless new_group_info

      logger.debug "Fetched group info: #{new_group_info.inspect})"

      User.users.values.each do |user|
        next unless user.department == group_info[:sid] && user.group == group_info[:gr]

        user.department = new_group_info[:sid]
      end

      new_group_info
    end

    def try_timeout(times: MAX_RETRIES, raise_on_failure: true, &block)
      retries = times
      delay = 1
      begin
        return block.call
      rescue => e
        retries -= 1
        if retries > 0
          logger.warn "Failed to load page, retrying... (#{retries} retries left)"
          sleep delay
          delay *= 2
          retry
        else
          logger.error "Failed to load page after #{times} retries"
          raise e if raise_on_failure
        end
      end
    end
  
    def parse_schedule_table(table)
      unless table
        logger.warn "Table is nil: #{table.inspect}"
        return nil
      end

      logger.info "Parsing html table..."

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
          logger.error "Failed to parse time range."
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
