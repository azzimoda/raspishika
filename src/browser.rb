# frozen_string_literal: true

require 'playwright' # NOTE: Playwright is synchronouse YET

require_relative 'logger'

module Raspishika
  class BrowserManager
    GlobalLogger.define_named_logger self

    def initialize
      @ready = false
      @mutex = Mutex.new
    end

    def ready?
      @browser && @thread && @ready
    end

    # Initializes a thread with running instance of Playwright browser Chrome.
    def run
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

    # Closes running browser and joins its thread.
    def stop
      return unless @browser && @thread

      @browser.close
      @thread.join
    end

    def with_browser
      if ready?
        return @mutex.synchronize { yield @browser } if block_given?

        @browser
      end

      logger.info 'Initilizing browser...'
      Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
        browser = playwright.chromium.launch headless: true, timeout: TIMEOUT * 1000
        return yield browser if block_given?

        browser
      end
    end

    def with_page
      with_browser do |browser|
        page = browser.new_page
        raise ArgumentError, 'No block' unless block_given?

        yield page
      ensure
        page.close
      end
    end
  end
end
