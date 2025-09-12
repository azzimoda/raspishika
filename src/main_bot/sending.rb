# frozen_string_literal: true

require 'concurrent'
require 'time'

module Raspishika
  class Bot
    def daily_sending_loop
      logger.info 'Starting daily sending loop...'
      last_sending_time = Time.now - 2 * 60

      sending_thread_pool = Concurrent::FixedThreadPool.new 20

      while @run
        current_time = Time.now

        chats = Chat.where.not(daily_sending_time: nil).select do |chat|
          Time.parse(chat.daily_sending_time).between? last_sending_time, current_time
        end

        futures = chats.map do |chat|
          Concurrent::Future.execute(executor: sending_thread_pool) do
            start_time = Time.now
            send_week_schedule nil, chat, Session[chat]
            logger.debug "Daily schedule sent to @#{chat.username} ##{chat.tg_id}"
            chat.push_daily_sending_report conf_time: it.daily_sending, process_time: Time.now - start_time, ok: true
          rescue StandardError => e
            chat.push_daily_sending_report conf_time: it.daily_sending, process_time: Time.now - start_time, ok: false
            msg = "Error while sending daily schedule: #{e.detailed_message}"
            report msg, backtrace: e.backtrace.join("\n"), code: true
            logger.error msg
            logger.error e.backtrace.join("\n\t")
          end
        end
        futures.each(&:wait)

        logger.debug "Daily sending for #{chats.count} users took #{Time.now - current_time} seconds" if chats.any?

        last_sending_time = current_time

        60.times do
          break unless @run

          sleep 1
        end
      end

      sending_thread_pool.shutdown
      sending_thread_pool.wait_for_termination 60
      sending_thread_pool.kill if sending_thread_pool.running?
    end

    private

    def schedule_pair_sending
      logger.info 'Scheduling pair sending...'

      ['8:00', '9:45', '11:30', '13:45', '15:30', '17:15', '19:00'].each do |time|
        logger.debug "Scheduling sending for #{time}..."
        time = Time.parse time

        sending_time = time - 15 * 60
        @scheduler.cron("#{sending_time.min} #{sending_time.hour} * * 1-6") { send_pair_notification time }
      end
    end

    def send_pair_notification(time, chat: nil)
      logger.info "Sending pair notification for #{time}..."

      sending_thread_pool = Concurrent::FixedThreadPool.new 20

      groups =
        if chat
          logger.debug "Sending pair notification for #{time} to #{chat.tg_id} with group #{chat.group_info}..."
          { [chat.department, chat.group] => [chat] }
        else
          Chat.where(pair_sending: true).group_by { [it.department, it.group] }
        end
      logger.debug "Sending pair notification to #{groups.size} groups..."

      futures = groups.map do |(_dname, gname), chats|
        Concurrent::Future.execute(executor: sending_thread_pool) do
          send_pair_notification_for_group(chats, time)
        rescue StandardError => e
          logger.error "Failed to send pair notification for #{gname}: #{e.detailed_message}"
          logger.error e.backtrace.join("\n\t")
        end
      end
      futures.each(&:wait)

      sending_thread_pool.shutdown
      sending_thread_pool.wait_for_termination 60
      sending_thread_pool.kill if sending_thread_pool.running?
    end

    def send_pair_notification_for_group(chats, time)
      if chats.empty?
        logger.warn 'Chats array is empty'
        return
      end

      logger.info "Sending pair notification to #{chats.size} chats of group #{chats.first.group}..."

      raw_schedule = @parser.fetch_schedule chats.first.group_info
      if raw_schedule.nil?
        logger.error "Failed to fetch schedule for #{chats.first.group_info}"
        return
      end

      pair = Schedule.from_raw(raw_schedule).now(time: time)&.pair(0)
      return unless pair

      text =
        case pair.data.dig(0, :pairs, 0, :type)
        when :subject, :exam, :consultation
          format("Следующая пара в кабинете %<classroom>s:\n%<discipline>s\n%<teacher>s",
                 pair.data.dig(0, :pairs, 0, :content))
        else
          logger.debug 'No pairs left for the group'
          return
        end

      logger.debug "Sending pair notification to #{chats.size} chats of group #{chats.first.group}..."
      chats.map(&:tg_id).each do |chat_id|
        bot.api.send_message(chat_id: chat_id, text: text)
      rescue StandardError => e
        logger.error "Failed to send pair notification of group #{chats.first.group} to #{chat_id}:" \
                     "#{e.detailed_message}"
        logger.error e.backtrace.join("\n\t")
      end
    end
  end
end
