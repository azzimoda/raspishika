require 'minitest/autorun'
require 'minitest/spec'

describe "General" do
  before do
    require 'logger'
    require 'nokogiri'
    require 'open-uri'
    require 'uri'
    require 'cgi'
    require 'selenium-webdriver'
    require 'timeout'
    
    require './parser'

    @logger = Logger.new($stderr)
    @parser = ScheduleParser.new(logger: @logger)
    @test_schedule_table_html = File.read('./schedule.html')
  end

  it 'should fetch schedule html' do
    url = "https://coworking.tyuiu.ru/shs/all_t/sh.php" \
    "?action=group&union=0&sid=#{28703}&gr=#{427}&year=#{Time.now.year}&vr=1"
    @logger.info "Fetching schedule from: #{url}"

    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--headless')
    options.add_argument('--disable-gpu')
    options.add_argument('--no-sandbox')

    driver = Selenium::WebDriver.for(:chrome, options: options)
    begin
      driver.navigate.to(url)
      wait = Selenium::WebDriver::Wait.new(timeout: 60)

      @logger.info "Waiting for table..."
      _ = wait.until { driver.find_element(id: 'main_table') }
      html = driver.page_source
      File.write('schedule_test_fetching.html', html)
      # doc = Nokogiri::HTML html
    ensure
      driver&.quit
    end
  end

  it 'should fetch schedule table' do
    schedule = @parser.fetch_schedule({sid: 28703, gr: 427})
    # pp schedule
    # pp_schedule schedule
    # pp transform_schedule_to_days schedule
    puts format_schedule_days transform_schedule_to_days schedule
  end

  it 'should parse schedule table' do
    schedule = @parser.parse_schedule_table Nokogiri::HTML @test_schedule_table_html
    # pp schedule
    # pp_schedule schedule
    # pp transform_schedule_to_days schedule
    puts format_schedule_days transform_schedule_to_days schedule
  end
end