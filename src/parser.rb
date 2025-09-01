# frozen_string_literal: true

require 'nokogiri'
require 'open-uri'
require 'uri'
require 'cgi'
require 'playwright' # NOTE: Playwright is synchronouse YET
require 'timeout'
require 'pp'
require 'user_agent_randomizer'

require_relative 'cache'
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

    def fetch_departments(unsafe_cache: false)
      Cache.fetch :departments, expires_in: LONG_CACHE_TIME, file: true, unsafe: unsafe_cache do
        logger.info 'Fetching departments...'

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
    rescue StandardError => e
      logger.error "Unhandled error in `#fetch_departments`: #{e.detailed_message}"
      logger.error "Backtrace:\n#{e.backtrace.join("\n")}"
      nil
    end

    def fetch_all_groups(departments_urls, unsafe_cache: false)
      logger.info 'Fetching all groups...'
      Cache.fetch :groups, expires_in: LONG_CACHE_TIME, file: true, unsafe: unsafe_cache do
        departments_urls.each_with_object({}) do |(name, url), groups|
          groups[name] = fetch_groups url, name, unsafe_cache: true
        end
      end
    end

    def fetch_groups(department_url, department_name, unsafe_cache: false)
      if department_url.nil? || department_url.empty?
        raise ArgumentError, "department_url is `nil` or empty: #{department_url.inspect}"
      end

      Cache.fetch :"groups_#{department_name}", expires_in: LONG_CACHE_TIME, file: true, unsafe: unsafe_cache do
        logger.info "Fetching groups for #{department_url}"

        options = use_browser do |browser|
          page = browser.new_page
          try_timeout do
            page.goto(department_url, timeout: TIMEOUT * 1000)

            iframe = page.wait_for_selector('div.com-content-article__body iframe', timeout: TIMEOUT * 1000)
            frame = iframe.content_frame

            select = frame.wait_for_selector('#groups', timeout: TIMEOUT * 1000)
            raise 'Failed to find groups selector' if select.nil?

            frame.eval_on_selector_all(
              '#groups option',
              'els => els.map(el => ({ text: el.textContent.trim(), value: el.value, sid: el.getAttribute("sid") }))'
            )
          end
        ensure
          page.close
        end

        options.each_with_object({}) do |opt, groups|
          next if opt['value'] == '0'

          groups[opt['text']] = { gr: opt['value'], sid: opt['sid'] }
        end
      end
    rescue StandardError => e
      logger.error "Unhandled error in `#fetch_groups`: #{e.detailed_message}"
      logger.error "Backtrace:\n#{e.backtrace.join("\n")}"
      nil
    end

    def fetch_schedule(group_info)
      unless group_info[:department] && group_info[:group]
        logger.error 'Wrong group data'
        return nil
      end

      groups_data = fetch_all_groups fetch_departments
      group_info = group_info.merge groups_data.dig group_info[:department], group_info[:group]

      Cache.fetch :"schedule_#{group_info[:sid]}_#{group_info[:gr]}" do
        logger.info "Fetching schedule for #{group_info}"

        base_url = "https://coworking.tyuiu.ru/shs/all_t/sh#{group_info[:zaochnoe] ? 'z' : ''}.php"
        url = "#{base_url}?action=group&union=0" \
              "&sid=#{group_info[:sid]}&gr=#{group_info[:gr]}&year=#{Time.now.year}&vr=1"
        logger.debug "URL: #{url}"

        schedule =
          if (schedule = try_fetch_schedule(url, times: 2, raise_on_failure: false))
            schedule
          else
            logger.warn 'Failed to load page, trying to update department ID...'

            new_group_info = update_department_id group_info, unsafe_cache: true
            group_info = group_info.merge new_group_info
            url = "#{base_url}?action=group&union=0&sid=#{new_group_info[:sid]}&gr=#{new_group_info[:gr]}" \
                  "&year=#{Time.now.year}&vr=1"
            logger.debug "URL: #{url}"

            # Second try with updated department ID
            try_fetch_schedule url
          end

        use_browser do |browser|
          page = browser.new_page
          ImageGenerator.generate page, schedule, group_info: group_info
          page.close
        end

        schedule
      end
    end

    def try_fetch_schedule(url, teacher: false, **kwargs)
      html = nil
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

          logger.debug 'Waiting for table...'
          page.wait_for_selector('#main_table', timeout: TIMEOUT * 1000)
          html = page.content
        end
        page.close
      end

      unless html
        return nil if kwargs[:raise_on_failure] == false

        raise "Failed to load page after #{MAX_RETRIES} retries"
      end

      doc = Nokogiri::HTML html
      schedule = parse_schedule_table(doc.at_css('table#main_table'), teacher: teacher)
      raise 'Failed to find table#main_table.' if schedule.nil? && kwargs[:raise_on_failure] == false

      schedule
    rescue Playwright::TimeoutError => e
      logger.error "Timeout error while parsing schedule: #{e.detailed_message}"
      logger.debug e.backtrace.join "\n"
      nil
    ensure
      debug_dir = File.join('data', 'debug')
      Dir.mkdir(debug_dir) unless Dir.exist?(debug_dir)
      # Saving original HTML into data/debug/schedule.html for debug
      File.write(File.join(debug_dir, 'schedule.html'), html)
    end

    def fetch_teachers_names(cache: true)
      # TODO? Maybe I should fetch it like departments' links?
      teachers_url = 'https://mnokol.tyuiu.ru/site/index.php?option=com_content&view=article&id=1247&Itemid=304'
      Cache.fetch :teachers_names, expires_in: cache ? 24 * 60 * 60 : 0, file: true do
        logger.info "Fetching teachers' names..."
        options = use_browser do |browser|
          page = browser.new_page
          try_timeout do
            page.goto teachers_url, timeout: TIMEOUT * 1000

            iframe = page.wait_for_selector 'div.com-content-article__body iframe', timeout: TIMEOUT * 1000
            frame = iframe.content_frame
            select = frame.wait_for_selector '#preps', timeout: TIMEOUT * 1000
            raise 'Failed to find preps selector' unless select

            frame.eval_on_selector_all(
              '#preps option',
              'els => els.map(el => ({ text: el.textContent.trim(), value: el.value }))'
            )
          end
        ensure
          page.close
        end
        logger.debug "Fetched options: #{options.inspect}"

        options.each_with_object({}) { |opt, teachers| teachers[opt['text']] = opt['value'] }
      end
    end

    def fetch_teacher_schedule(teacher_id, teacher_name)
      groups = fetch_all_groups fetch_departments
      sids = groups.each_value.map { it.first&.last&.dig(:sid) }.compact

      Cache.fetch :"teacher_schedule_#{teacher_id}" do
        base_url = 'https://coworking.tyuiu.ru/shs/all_t/sh.php'
        url = "#{base_url}?action=prep&prep=#{teacher_id}&vr=1&count=#{sids.size}" +
              sids.each_with_index.map { |sid, i| "&shed[#{i}]=#{sid}&union[#{i}]=0&year[#{i}]=#{Time.now.year}" }.join
        logger.debug "URL: #{url}"

        try_fetch_schedule(url, teacher: true).tap do |s|
          use_browser do |browser|
            page = browser.new_page
            ImageGenerator.generate page, s, teacher_id: teacher_id, teacher_name: teacher_name
            page.close
          end
        end
      end
    end

    def generate_headers
      {
        'User-Agent' => UserAgentRandomizer::UserAgent.fetch.string,
        'Referer' => 'https://coworking.tyuiu.ru/shs/all_t/',
        'Accept-Language' => "#{%w[ru-RU,ru en-US,en].sample};q=0.#{rand(5..9)}"
      }.tap do |a|
        # NOTE: This may be not necessary.
        { 'Sec-Fetch-Dest' => 'document', 'Sec-Fetch-Mode' => 'navigate', 'Connection' => 'keep-alive' }
          .each { |k, v| a[k] = v if rand(2).zero? }
      end
    end

    def update_department_id(group_info, unsafe_cache: false)
      # Update department ID for all users in the group.
      deps = fetch_departments unsafe_cache: unsafe_cache
      groups = fetch_all_groups deps, unsafe_cache: unsafe_cache
      new_group_info = groups.dig group_info[:department], group_info[:group]

      logger.debug "Fetched group info: #{new_group_info.inspect})"
      new_group_info
    end

    def try_timeout(times: MAX_RETRIES, raise_on_failure: true, &block)
      retries = times
      delay = 1
      begin
        block.call
      rescue StandardError => e
        retries -= 1
        if retries.positive?
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

    def parse_schedule_table(table, teacher: false)
      unless table
        logger.warn "Table is nil: #{table.inspect}"
        return nil
      end

      logger.info 'Parsing html table...'

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
          logger.error 'Failed to parse time range.'
          return nil
        end
        time_range = time_range.text.strip

        time_slot = { pair_number: pair_number, time_range: time_range, days: [] }
        row.css('td:nth-child(n+3)').each_with_index do |day_cell, day_index|
          day_info = day_headers[day_index] || {}
          day_info[:replaced] = day_cell.css('table.zamena').any?
          day_info[:consultation] = day_cell.css('table.consultation').any?
          time_slot[:days] << parse_day_entry(day_cell, day_info, teacher: teacher)
        end
        schedule << time_slot
      end
      schedule
    end
  
    private

    def parse_day_entry(day_cell, day_info, teacher: false)
      day_info = day_info.merge \
        case
        when day_cell['class']&.include?('head_urok_block') && day_cell.text.strip.downcase == 'нет занятий'
          { type: :empty }
        when day_cell.text.downcase.include?('снято') || day_cell.at_css('.disc')&.text&.strip&.empty?
          { type: :empty }
        when day_cell['class']&.include?('head_urok_iga')
          { type: :iga, content: day_cell.text.strip }
        when day_cell['class']&.include?('event')
          { type: :event, content: day_cell.text.strip }
        when day_cell['class']&.include?('head_urok_praktik')
          { type: :practice, content: day_cell.text.strip }
        when day_cell['class']&.include?('head_urok_session')
          { type: :session, content: day_cell.text.strip }
        when day_cell['class']&.include?('head_urok_kanik')
          { type: :vacation, content: day_cell.text.strip }
        when day_cell.css('table.zachet').any? || day_cell.css('table.difzachet').any? ||
             day_cell.css('table.ekzamen').any?
          { type: :exam, title: day_cell.at_css('.head_ekz').text.strip, content: {
            discipline: day_cell.at_css('.disc'),
            teacher: day_cell.at_css('.prep')&.text&.strip,
            classroom: day_cell.at_css('.cab')&.text&.strip
          } }
        when day_info[:consultation]
          { type: :consultation, title: day_cell.at_css('.head_ekz').text.strip, content: {
            discipline: day_cell.at_css('.disc'),
            teacher: day_cell.at_css('.prep')&.text&.strip,
            classroom: day_cell.at_css('.cab')&.text&.strip
          } }
        else
          { type: :subject, content: {
            discipline: day_cell.at_css('.disc'),
            teacher: day_cell.at_css('.prep')&.text&.strip,
            classroom: day_cell.at_css('.cab')&.text&.strip
          } }
        end
      if day_info.dig(:content, :discipline)
        if teacher
          disc, group = day_info[:content][:discipline]&.then do |el|
            el.children.select { it.text? || it.element? && it.name == 'div' }.map { it.text.strip }
          end
          day_info[:content][:discipline] = disc
          day_info[:content][:group] = group
        else
          day_info[:content][:discipline] = day_info[:content][:discipline]&.text&.strip
        end
      end
      day_info
    end
  end
end
