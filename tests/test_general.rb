require 'minitest/autorun'
require 'minitest/spec'

require 'logger'
require 'nokogiri'
require 'open-uri'
require 'uri'
require 'cgi'
require 'selenium-webdriver'
require 'timeout'

require "./src/parser"
require './src/schedule'

describe ScheduleParser do
  let(:logger) { Logger.new $stdout }
  let(:parser) { ScheduleParser.new logger: }

  before do
    @test_schedule_table_html = File.read './.debug/schedule.html'
  end

  it 'should fetch schedule html' do
    url = "https://coworking.tyuiu.ru/shs/all_t/sh.php" \
    "?action=group&union=0&sid=#{28703}&gr=#{427}&year=#{Time.now.year}&vr=1"
    logger.info "Fetching schedule from: #{url}"

    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--headless')
    options.add_argument('--disable-gpu')
    options.add_argument('--no-sandbox')

    driver = Selenium::WebDriver.for(:chrome, options: options)
    begin
      driver.navigate.to(url)
      wait = Selenium::WebDriver::Wait.new(timeout: 60)

      logger.info "Waiting for table..."
      _ = wait.until { driver.find_element(id: 'main_table') }
      html = driver.page_source
      File.write('schedule_test_fetching.html', html)
      # doc = Nokogiri::HTML html
    ensure
      driver&.quit
    end
  end

  it 'must fetch schedule table' do
    schedule = Schedule.from_raw parser.fetch_schedule({sid: 28703, gr: 427})
    # pp schedule.transform
    puts schedule.format
  end

  it 'must parse schedule table' do
    schedule = parser.parse_schedule_table Nokogiri::HTML @test_schedule_table_html
    # pp schedule.transform
    puts schedule.format
  end
end

describe Schedule do
  let(:logger) { Logger.new $stdout }
  let(:parser) { ScheduleParser.new logger: }

  before do
    # @test_schedule_table_html = File.read('./.debug/schedule.html')
    # @test_schedule_data = parser.parse_schedule_table Nokogiri::HTML @test_schedule_table_html
    @schedule = Time.parse('2025-04-02').then { |t|
      Schedule.new [{
        date: t,
        weekday: 'Понедельник',
        week_type: "Чётная",
        pairs: [
          {time_range: '9:45 - 11:20',
            type: :subject,
            replaced: false,
            subject: {discipline: 'Dist 1'}},
          {time_range: '11:30 - 13:05',
            type: :subject,
            replaced: false,
            subject: {discipline: 'Dist 1'}},
          {time_range: '13:45 - 15:20',
            type: :subject,
            replaced: false,
            subject: {discipline: 'Dist 1'}}
        ]
      }]
    }
  end

  describe '#now' do
    it 'must return current pair (1st)' do
      _(pp @schedule.now time: Time.parse('11:00')).must_equal(
        @schedule.deep_clone.tap { |s| s.data[0][:pairs].slice!(1..) }
      )
    end
  end

  describe '#left' do
    it 'must return schedule of whole day' do
      _(@schedule.left from: Time.parse('7:00')).must_equal @schedule
    end

    it 'must return lst two pairs (3rd and 4th)' do
      _(@schedule.left from: Time.parse('12:00'))
    end

    it 'must return the last pair' do
      pp @schedule.left from: Time.parse('13:20')
    end

    it 'must return nil' do
      _(@schedule.left from: Time.parse('22:00')).must_be_nil
    end
  end
end
