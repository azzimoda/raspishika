require 'logger'
require 'telegram/bot'
require 'nokogiri'
require 'open-uri'
require 'uri'
require 'cgi'
require 'selenium-webdriver'
require 'timeout'

# Конфигурация бота
TOKEN = File.read('.token').chomp.freeze

# Базовый URL сайта колледжа
BASE_URL = 'https://mnokol.tyuiu.ru'.freeze

$logger = Logger.new $stderr

# Класс для парсинга расписания
class ScheduleParser
  def initialize
    @departments = {}
    @group_schedules = {}
    @user_context = {} # Для хранения контекста пользователей
  end
  attr_reader :user_context

  # Получаем список отделений
  def fetch_departments
    $logger.info "Fetching departaments..."

    url = "#{BASE_URL}/site/index.php?option=com_content&view=article&id=1582&Itemid=247"
    doc = Nokogiri::HTML(URI.open(url))

    doc.css('ul.mod-menu li.col-lg.col-md-6 a').each do |link| # Add classes .col-lg and .col-md-6 to li
      department_name = link.text.strip
      department_url = link['href'].gsub('&amp;', '&')
      @departments[department_name] = "#{BASE_URL}#{department_url}"
    end

    @departments
  rescue => e
    $logger.error "Error fetching departments: #{e.message}"
    {}
  end

  # Получаем список групп для отделения
  def fetch_groups(department_url)
    $logger.info "Fetching groups for #{department_url}"

    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--headless')
    options.add_argument('--disable-gpu')
    options.add_argument('--no-sandbox')
    options.add_argument("--user-data-dir=/tmp/chrome_profile_#{rand(10000)}")

    driver = Selenium::WebDriver.for(:chrome, options: options)
    begin
      driver.navigate.to(department_url)
      wait = Selenium::WebDriver::Wait.new(timeout: 20)

      # Switch to iframe
      iframe = wait.until { driver.find_element(:css, 'div.com-content-article__body iframe') }
      driver.switch_to.frame(iframe)

      # Wait for groups select
      select = wait.until { driver.find_element(:id, 'groups') }
      groups = {}

      select.find_elements(:tag_name, 'option').each do |option|
        next if option['value'] == '0' # Skip placeholder
        groups[option.text.strip] = option['value']
      end

      groups
    rescue => e
      $logger.error "Error fetching groups: #{e.message}"
      {}
    ensure
      driver.quit if driver
    end
  end

  # Получаем расписание для группы
  def fetch_schedule(department_url, group_id)
    $logger.info "Fetching schedule for group #{group_id}..."

    begin
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument('--headless')
      options.add_argument('--disable-gpu')
      options.add_argument('--no-sandbox')
      options.add_argument('--disable-dev-shm-usage')
      options.add_argument("--user-data-dir=/tmp/chrome_#{rand(10000)}")

      driver = Selenium::WebDriver.for(:chrome, options: options)

      driver.navigate.to(department_url)
      wait = Selenium::WebDriver::Wait.new(timeout: 20)

      # Switch to iframe
      iframe = wait.until { driver.find_element(:css, 'div.com-content-article__body iframe') }
      driver.switch_to.frame(iframe)

      # Select group
      select = wait.until { driver.find_element(:id, 'groups') }
      Selenium::WebDriver::Support::Select.new(select).select_by(:value, group_id)

      # Click show button
      driver.find_element(:id, 'click_to_show').click

      # Get schedule
      schedule = wait.until { driver.find_element(:id, 'main_table') }.text

      schedule.empty? ? "Расписание не найдено" : schedule
    rescue Selenium::WebDriver::Error::TimeoutError => e
      $logger.error "Timeout error: #{e.message}"
      "Не удалось загрузить расписание: превышено время ожидания"
    rescue => e
      $logger.error "Error fetching schedule: #{e.message}"
      "Произошла ошибка при получении расписания"
    ensure
      driver.quit if defined?(driver) && driver
    end
  end

  private

  # Пример расписания (заглушка)
  def example_schedule(department_url, group_id)
    schedule = []
    schedule << "📅 Расписание для группы #{group_id}"
    schedule << "Понедельник:"
    schedule << "1. 08:00-09:35 - Математика (ауд. 101)"
    schedule << "2. 09:45-11:20 - Физика (ауд. 205)"
    schedule << ""
    schedule << "Вторник:"
    schedule << "3. 11:30-13:05 - Программирование (ауд. 310)"
    schedule << "4. 13:45-15:20 - Базы данных (ауд. 215)"

    schedule.join("\n")
  end
end

# Инициализация парсера
parser = ScheduleParser.new

# Запуск бота
$logger.info "Starting bot..."

Telegram::Bot::Client.run(TOKEN) do |bot|
  bot.listen do |message|
    begin
      $logger.debug "Received: #{message.text}"

      case message.text
      when '/start'
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Привет! Используй /departments чтобы начать"
        )

      when '/departments'
        departments = parser.fetch_departments
        if departments.any?
          # Создаем клавиатуру правильно
          keyboard = departments.keys.each_slice(2).map do |pair|
            pair.map { |department| { text: department } }
          end

          markup = {
            keyboard: keyboard,
            resize_keyboard: true,
            one_time_keyboard: true
          }

          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Выберите отделение:",
            reply_markup: JSON.dump(markup)
          )
        else
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Не удалось загрузить отделения"
          )
        end
      else
        # Если это название отделения
        departments = parser.fetch_departments
        if departments.key?(message.text)
          parser.user_context[message.chat.id] = {
            department: message.text,
            department_url: departments[message.text]
          }

          groups = parser.fetch_groups(departments[message.text])
          if groups.any?
            # Формируем клавиатуру с группами (по 1 в ряд)
            keyboard = groups.keys.map { |group| [group] }

            bot.api.send_message(
              chat_id: message.chat.id,
              text: "Выберите группу:",
              reply_markup: {
                keyboard: keyboard,
                resize_keyboard: true,
                one_time_keyboard: true
              }.to_json
            )
          else
            bot.api.send_message(
              chat_id: message.chat.id,
              text: "Не удалось загрузить группы для этого отделения"
            )
          end

        # Если это номер группы и есть контекст
        elsif parser.user_context[message.chat.id]
          context = parser.user_context[message.chat.id]

          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Загружаю расписание, пожалуйста подождите..."
          )

          schedule = parser.fetch_schedule(context[:department_url], message.text)
          bot.api.send_message(
            chat_id: message.chat.id,
            text: schedule || "Расписание не найдено"
          )

          # Очищаем контекст
          parser.user_context.delete(message.chat.id)
        else
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Пожалуйста, сначала выберите отделение через /departments"
          )
        end
      end
    rescue => e
      $logger.error "Error: #{e.message}"
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Произошла ошибка. Попробуйте позже."
      )
    end
  end
end
