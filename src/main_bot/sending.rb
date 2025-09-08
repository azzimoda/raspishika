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

        users_to_send = User.users.each_value.select do |chat|
          chat.daily_sending && Time.parse(chat.daily_sending).between?(last_sending_time, current_time)
        end

        futures = users_to_send.map do |chat|
          Concurrent::Future.execute(executor: sending_thread_pool) do
            start_time = Time.now
            send_week_schedule nil, chat
            logger.debug "Daily schedule sent to #{chat.id} (#{bot.api.get_chat(chat_id: chat.id).username})"
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

        if users_to_send.any?
          logger.debug "Daily sending for #{users_to_send.size} users took #{Time.now - current_time} seconds"
        end

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

    def send_pair_notification(time, user: nil)
      logger.info "Sending pair notification for #{time}..."

      sending_thread_pool = Concurrent::FixedThreadPool.new 20

      groups =
        if user
          logger.debug "Sending pair notification for #{time} to #{user.id} with group #{user.group_info}..."
          { [user.department_name, user.group_name] => [user] }
        else
          User.users.values.select(&:pair_sending).group_by { [it.department_name, it.group_name] }
        end
      logger.debug "Sending pair notification to #{groups.size} groups..."

      futures = groups.map do |(_dname, gname), users|
        Concurrent::Future.execute(executor: sending_thread_pool) do
          send_pair_notification_for_group(users, time)
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

    def send_pair_notification_for_group(users, time)
      if users.empty?
        logger.warn 'Users array is empty'
        return
      end

      logger.info "Sending pair notification to #{users.size} users of group #{users.first.group_name}"

      raw_schedule = @parser.fetch_schedule users.first.group_info
      if raw_schedule.nil?
        logger.error "Failed to fetch schedule for #{users.first.group_info}"
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

      logger.debug "Sending pair notification to #{users.size} users of group #{users.first.group_name}..."
      users.map(&:id).each do |chat_id|
        bot.api.send_message(chat_id: chat_id, text: text)
      rescue StandardError => e
        logger.error "Failed to send pair notification of group #{users.first.group_name} to #{chat_id}:" \
                     "#{e.detailed_message}"
        logger.error e.backtrace.join("\n\t")
      end
    end
  end
end
