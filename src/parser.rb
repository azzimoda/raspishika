# frozen_string_literal: true

require 'nokogiri'
require 'net/http'
require 'open-uri'
require 'uri'
require 'cgi'
require 'playwright' # NOTE: Playwright is synchronouse YET
require 'timeout'
require 'pp'
require 'user_agent_randomizer'
require 'fileutils'

require_relative 'logger'
require_relative 'cache'
require_relative 'image_generator'

module Raspishika
  class ScheduleParser
    GlobalLogger.define_named_logger self

    TIMEOUT = Config[:parser][:timeout]
    MAX_RETRIES = Config[:parser][:max_retries]
    LONG_CACHE_TIME = 30 * 24 * 60 * 60 # 1 month
    BASE_URL = 'https://mnokol.tyuiu.ru'
    DEPARTMENTS_PAGE_URL = 'https://mnokol.tyuiu.ru/site/index.php?option=com_content&view=article&id=1582&Itemid=247'
    TEACHERS_URL = 'https://mnokol.tyuiu.ru/site/index.php?option=com_content&view=article&id=1247&Itemid=304'
    DEBUG_DIR = File.expand_path '../data/debug', __dir__

    FileUtils.mkdir_p DEBUG_DIR

    def initialize
      @thread = nil
      @browser = nil
      @ready = false
      @mutex = Mutex.new

      @schedule_scraper = method select_scraper Config[:parser][:fetch_schedule_with_browser]
      @teacher_schedule_scraper = method select_scraper Config[:parser][:fetch_teacher_schedule_with_browser]

      logger.debug "@schedule_scraper: #{@schedule_scraper.name}"
      logger.debug "@teacher_schedule_scraper: #{@teacher_schedule_scraper.name}"
    end
    attr_accessor :ready

    def ready?
      @ready
    end

    def initialize_browser_thread
      unless Config[:parser][:browser][:threaded]
        logger.info 'Browser thread initialization skipped'
        return
      end

      @thread = Thread.new do
        Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
          @browser = playwright.chromium.launch(headless: true)
          logger.info 'Browser is ready'
          @ready = true
          sleep 0.1 while @browser.connected?
        end
        logger.info 'Browser thread is stopped'
      end
    end

    def stop_browser_thread
      return unless @browser && @thread

      logger.info 'Stopping browser thread...'
      @browser.close
      @thread.join
    end

    def with_browser(&block)
      if @browser && @thread && @ready
        @mutex.synchronize { block.call @browser }
      else
        logger.info 'Using browser...'
        Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
          browser = playwright.chromium.launch headless: true, timeout: TIMEOUT * 1000
          block.call browser
        end
      end
    end

    def with_page(&block)
      with_browser do |browser|
        page = browser.new_page
        block.call page
      ensure
        page.close
      end
    end

    # Scrapes names of departments and links to their pages.
    #
    # @param unsafe_cache [Boolean] whether use unsafe caching; defaults to `false`
    #
    # @return [Hash] URLs by departments names
    # @raise [RuntimeError] when fails to load page
    def fetch_departments(unsafe_cache: false)
      Cache.fetch :departments, expires_in: LONG_CACHE_TIME, file: true, unsafe: unsafe_cache do
        logger.info 'Fetching departments...'

        uri = URI.parse DEPARTMENTS_PAGE_URL
        resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          http.request Net::HTTP::Get.new(uri, generate_headers)
        end
        raise "Failed to load departments: #{resp.inspect}" if resp.code.to_i != 200

        Nokogiri::HTML(resp.body).css('ul.mod-menu li.col-lg.col-md-6 a').map do |link|
          name = html_to_text link
          next unless name.downcase.include?('отделение') || name.downcase == 'заочное обучение'

          [name, "#{BASE_URL}#{link['href'].gsub('&amp;', '&')}"]
        end.compact.to_h
      end
    rescue StandardError => e
      logger.error "Unhandled error in `#fetch_departments`: #{e.detailed_message}"
      logger.error "Backtrace:\n#{e.backtrace.join("\n")}"
      nil
    end

    def fetch_all_groups(unsafe_cache: false)
      departments_urls = fetch_departments
      Cache.fetch :groups, expires_in: LONG_CACHE_TIME, file: true, unsafe: unsafe_cache do
        logger.info 'Fetching all groups...'
        departments_urls.each_with_object({}) do |(name, url), groups|
          groups[name] = fetch_groups url, name, unsafe_cache: true
        end
      end
    end

    def fetch_groups(department_url, department_name, unsafe_cache: false)
      raise ArgumentError, 'department_url is `nil`' unless department_url

      Cache.fetch :"groups_#{department_name}", expires_in: LONG_CACHE_TIME, file: true, unsafe: unsafe_cache do
        logger.info "Fetching groups for #{department_url}"

        options = with_page do |page|
          try_timeout do
            page.goto(department_url, timeout: TIMEOUT * 1000)

            iframe = page.wait_for_selector('div.com-content-article__body iframe', timeout: TIMEOUT * 1000)
            frame = iframe.content_frame

            select = frame.wait_for_selector('#groups', timeout: TIMEOUT * 1000)
            raise 'Failed to find groups selector' unless select

            frame.eval_on_selector_all(
              '#groups option',
              'els => els.map(el => ({ text: el.textContent.trim(), value: el.value, sid: el.getAttribute("sid") }))'
            )
          end
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
        raise ArgumentError, "Wrong group data: #{group_info.inspect}"
      end

      if (data = fetch_all_groups.dig(group_info[:department], group_info[:group]))
        group_info = group_info.merge data
      else
        raise "Failed to get sid and gr by department and group names: #{group_info.inspect}"
      end

      schedule = Cache.fetch :"schedule_#{group_info[:sid]}_#{group_info[:gr]}" do
        logger.info "Fetching schedule for #{group_info}"

        url = make_group_schedule_url group_info
        if (schedule = @schedule_scraper.call(url, times: 2, raise_on_failure: false))
          schedule
        else
          logger.warn 'Failed to load page, trying to update department ID...'

          group_info = group_info.merge update_department_id group_info, unsafe_cache: true
          url = make_group_schedule_url group_info
          @schedule_scraper.call url # Second try with updated department ID
        end
      end

      generate_image schedule, group_info: group_info
      schedule
    end

    def scrape_schedule_with_browser(url, teacher: false, **kwargs)
      logger.debug "URL: #{url}"

      html = with_page do |page|
        try_timeout(**kwargs) do
          page.set_extra_http_headers(**generate_headers)
          page.goto url
          html = page.content

          logger.debug 'Waiting for table...'
          page.wait_for_selector '#main_table'
          html = page.content
        ensure
          File.write(File.join(DEBUG_DIR, 'schedule.html'), html)
        end
      end

      unless html
        return if kwargs[:raise_on_failure] == false

        raise "Failed to load page after #{MAX_RETRIES} retries"
      end

      schedule = parse_schedule_table html, teacher: teacher
      raise 'Failed to parse schedule table' if schedule.nil? && kwargs[:raise_on_failure] != false

      schedule
    rescue Playwright::TimeoutError => e
      logger.error "Timeout error while parsing schedule: #{e.detailed_message}"
      logger.debug e.backtrace.join "\n\t"
      nil
    end

    # Scrapes group's or teacher's schedule table from given URL.
    #
    # @param url [String] URL of schedule page
    # @param teacher [Boolean] whether parse schedule as teacher's; defaults to false
    # @param raise_on_failure [Boolean] whether raise exception when parser returned `nil`
    #
    # @return [Array] raw schedule as a HTML table
    # @raise [RuntimeError] if failed to parse schedule and `raise_on_failure` is `true`
    def scrape_schedule(url, teacher: false, raise_on_failure: true, **)
      logger.debug "URL: #{url}"

      html = nil
      uri = URI.parse url
      retries = 0
      resp = loop do
        resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          http.request Net::HTTP::Get.new(uri, generate_headers.tap { logger.debug it['User-Agent'] })
        end
        break resp if resp.code == '200'

        logger.warn "Failed to load schedule page #{url}: #{resp.inspect}"
        if (retries += 1) > MAX_RETRIES
          logger.error 'Out of retries'
          raise "Failed to load schedule page: #{url}: #{resp.inspect}" if raise_on_failure

          return
        end

        logger.warn "Retrying... (#{retries}/#{MAX_RETRIES})"
        sleep 1
      end

      html = fix_encoding resp.body.dup
      schedule = parse_schedule_table(html, teacher: teacher)
      raise 'Failed to parse schedule' if schedule.nil? && raise_on_failure

      schedule
    ensure
      File.write(File.join(DEBUG_DIR, 'schedule.html'), html)
    end

    def fix_encoding(text)
      text.force_encoding('Windows-1251').encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
    end

    def fetch_teachers(cache: true)
      Cache.fetch :teachers, expires_in: cache ? 24 * 60 * 60 : 0, file: true do
        logger.info "Fetching teachers' names..."
        options = with_page do |page|
          try_timeout do
            page.goto TEACHERS_URL

            iframe = page.wait_for_selector 'div.com-content-article__body iframe'
            frame = iframe.content_frame
            select = frame.wait_for_selector '#preps'
            raise 'Failed to find preps selector' unless select

            frame.eval_on_selector_all('#preps option',
                                       'els => els.map(el => ({ text: el.textContent.trim(), value: el.value }))')
          end
        end

        options.each_with_object({}) { |opt, teachers| teachers[opt['text']] = opt['value'] }
      end
    end

    def fetch_teacher_schedule(teacher_id, teacher_name)
      sids = fetch_all_groups.each_value.map { it.values.dig 0, :sid }.compact
      schedule = Cache.fetch :"teacher_schedule_#{teacher_id}" do
        logger.info "Fetching schedule for #{teacher_name}"

        url = make_teacher_schedule_url teacher_id, sids
        schedule = @teacher_schedule_scraper.call url, teacher: true
        raise "Failed to scrape teacher schedule: #{teacher_id}, #{teacher_name}" unless schedule

        schedule
      end

      generate_image schedule, teacher_id: teacher_id, teacher_name: teacher_name
      schedule
    end

    # Update department ID for all users in the group.
    def update_department_id(group_info, unsafe_cache: false)
      groups = fetch_all_groups unsafe_cache: unsafe_cache
      new_group_info = groups.dig group_info[:department], group_info[:group]

      logger.debug "Fetched group info: #{new_group_info.inspect})"
      new_group_info
    end

    private

    def make_group_schedule_url(group_info)
      "https://coworking.tyuiu.ru/shs/all_t/sh#{'z' if group_info[:zaochnoe]}.php" \
        "?action=group&union=0&sid=#{group_info[:sid]}&gr=#{group_info[:gr]}&year=#{Time.now.year}&vr=1"
    end

    def make_teacher_schedule_url(teacher_id, sids)
      "https://coworking.tyuiu.ru/shs/all_t/sh.php?action=prep&prep=#{teacher_id}&vr=1&count=#{sids.size}" +
        sids.map.with_index { |sid, i| "&shed[#{i}]=#{sid}&union[#{i}]=0&year[#{i}]=#{Time.now.year}" }.join
    end

    def generate_image(...)
      with_page { ImageGenerator.generate(it, ...) }
    end

    def generate_headers
      {
        'User-Agent' => UserAgentRandomizer::UserAgent.fetch.string,
        'Referer' => 'https://coworking.tyuiu.ru/shs/all_t/'
      }
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

    def parse_schedule_table(html, teacher: false)
      table = Nokogiri::HTML(html).at_css('table#main_table')
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

      table.css('tr.para_num:not(:first-child)').each_with_object([]) do |row, schedule|
        schedule << parse_row(row, day_headers, teacher: teacher)
      end
    end

    def parse_row(row, day_headers, teacher: false)
      return if row.css('th').any? # TODO: Remember why I do this.

      time_cell = row.at_css('td:first-child')
      raise 'Failed to find time cell' unless time_cell

      pair_number = time_cell.text.strip
      time_range = row.at_css 'td:nth-child(2)'
      raise 'Failed to parse time rage' unless time_range

      time_slot = { pair_number: pair_number, time_range: time_range.text.strip, days: [] }
      row.css('td:nth-child(n+3)').each_with_index do |day_cell, day_index|
        day_info = day_headers[day_index] || {}
        day_info[:replaced] = day_cell.css('table.zamena').any?
        day_info[:consultation] = day_cell.css('table.consultation').any?
        time_slot[:days] << parse_day_entry(day_cell, day_info, teacher: teacher)
      end
      time_slot
    end

    def parse_day_entry(day_cell, day_info, teacher: false)
      css_class = day_cell['class']
      day_info = day_info.merge \
        case
        when no_pair?(day_cell) || cancelled?(day_cell) then make_day :empty
        when css_class&.include?('head_urok_iga') then make_day :iga, content: html_to_text(day_cell)
        when css_class&.include?('event') then make_day :event, content: html_to_text(day_cell)
        when css_class&.include?('head_urok_praktik') then make_day :practice, content: html_to_text(day_cell)
        when css_class&.include?('head_urok_session') then make_day :session, content: html_to_text(day_cell)
        when css_class&.include?('head_urok_kanik') then make_day :vacation, content: html_to_text(day_cell)
        when exam?(day_cell)
          make_day(
            :exam,
            title: html_to_text(day_cell.at_css('.head_ekz')),
            content: { discipline: day_cell.at_css('.disc'), teacher: html_to_text(day_cell.at_css('.prep')),
                       classroom: html_to_text(day_cell.at_css('.cab')) }
          )
        when day_info[:consultation]
          make_day(
            :consultation,
            title: html_to_text(day_cell.at_css('.head_ekz')),
            content: { discipline: day_cell.at_css('.disc'), teacher: html_to_text(day_cell.at_css('.prep')),
                       classroom: html_to_text(day_cell.at_css('.cab')) }
          )
        else
          make_day(
            :subject,
            content: { discipline: day_cell.at_css('.disc'), teacher: html_to_text(day_cell.at_css('.prep')),
                       classroom: html_to_text(day_cell.at_css('.cab')) }
          )
        end

      if day_info.dig(:content, :discipline)
        if teacher
          disc, group = day_info.dig(:content, :discipline)&.then do |el|
            el.children.select { it.text? || it.element? && it.name == 'div' }.map { html_to_text it }
          end
          day_info[:content][:discipline] = disc
          day_info[:content][:group] = group
        else
          day_info[:content][:discipline] = html_to_text day_info.dig :content, :discipline
        end
      end
      day_info
    end

    def no_pair?(day_cell)
      day_cell['class']&.include?('head_urok_block') && html_to_text(day_cell).downcase == 'нет занятий'
    end

    def cancelled?(day_cell)
      day_cell.text.downcase.include?('снято') || day_cell.at_css('.disc')&.text&.strip&.empty?
    end

    def exam?(day_cell)
      day_cell.css('table.zachet').any? || day_cell.css('table.difzachet').any? || day_cell.css('table.ekzamen').any?
    end

    def html_to_text(html_element)
      html_element&.text&.strip
    end

    def make_day(type, content: nil, title: nil)
      { type: type, title: title, content: content }
    end

    def select_scraper(with_browser)
      with_browser ? :scrape_schedule_with_browser : :scrape_schedule
    end
  end
end
