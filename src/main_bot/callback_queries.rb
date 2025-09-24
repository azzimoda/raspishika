# frozen_string_literal: true

module Raspishika
  class Bot
    def handle_callback_query(query)
      args = query.data.split "\n"

      msg_chat = query.message.chat
      msg_from = query.from
      msg_end = "@#{msg_from.username} #{msg_from.full_name} <callback> #{args.join(' ; ')}"
      if msg_chat.type == 'private'
        logger.info "[#{msg_chat.id}] #{msg_end}"
      else
        logger.info "[#{msg_chat.id} @#{msg_chat.username} #{msg_chat.title}] #{msg_end}"
      end

      chat = Chat.find_by tg_id: query.message.chat.id

      case args[0]
      when 'update_week' then update_week_schedule(query, chat, *args[1..])
      when 'update_tomorrow' then update_tomorrow_schedule(query, chat, *args[1..])
      when 'update_left' then update_left_schedule(query, chat, *args[1..])
      when 'update_teacher' then update_teacher_schedule(query, chat, *args[1..])
      else logger.warn "Unexpected callback query data: #{query.data.inspect}"
      end
    end

    def update_week_schedule(query, chat, group)
      start_time = Time.now
      logger.debug "Updating schedule of group #{group}"

      department = parser.fetch_all_groups.find { |_, g| g.key? group }.first
      group_info = { department: department, group: group }
      schedule = parser.fetch_schedule group_info
      unless schedule
        send_update_error_message chat.tg_id
        report("Failed to fetch schedule for #{group_info}", photo: make_photo.call, log: 20)
        chat.log_command_usage '<update_week>', false, Time.now - start_time
        return
      end

      file_path = ImageGenerator.image_path group_info: group_info
      make_photo = -> { Faraday::UploadIO.new file_path, 'image/png' }

      Session[chat].tap do
        it.state = Session::State::DEFAULT
        it.save
      end

      successful = edit_message_photo(
        message: query.message,
        photo: make_photo.call,
        reply_markup: { inline_keyboard: make_update_inline_keyboard('update_week', group) }.to_json
      )
      chat.log_command_usage '<update_week>', successful, Time.now - start_time
    rescue StandardError => e
      send_update_error_message query.message.chat.id
      "Failed to update week schedule message: #{e.detailed_message}".tap do
        report it, backtrace: e.backtrace.join("\n"), log: 20
        logger.error it
        logger.error e.backtrace.join("\n\t")
      end
      chat.log_command_usage '<update_week>', false, Time.now - start_time
    end

    def update_tomorrow_schedule(query, chat, group)
      start_time = Time.now
      logger.debug "Updating tomorrow schedule of group #{group}..."

      schedule = parser.fetch_schedule chat.group_info
      unless schedule
        send_update_error_message chat.tg_id
        report("Failed to fetch schedule for #{group_info}", photo: make_photo.call, log: 20)
        chat.log_command_usage '<update_week>', false, Time.now - start_time
        return
      end

      Session[chat].tap do
        it.state = Session::State::DEFAULT
        it.save
      end

      tomorrow_schedule = schedule && Schedule.from_raw(schedule).day(Date.today.sunday? ? 0 : 1)
      text = tomorrow_schedule.nil? || tomorrow_schedule.all_empty? ? 'Завтра нет пар!' : tomorrow_schedule.format
      rm = { inline_keyboard: make_update_inline_keyboard('update_tomorrow', group) }.to_json
      successful =
        unless edit_message_text(message: query.message, text: text, parse_mode: 'Markdown', reply_markup: rm)
          handle_old_query_error chat do
            bot.api.answer_callback_query(callback_query_id: query.id, text: 'Ничего не изменилось')
          end
        end
      chat.log_command_usage '<update_tomorrow>', successful, Time.now - start_time
    rescue StandardError => e
      send_update_error_message query.message.chat.id
      "Failed to update tomorrow schedule message: #{e.detailed_message}".tap do
        report it, backtrace: e.backtrace.join("\n"), log: 20
        logger.error it
        logger.error e.backtrace.join("\n\t")
      end
      chat.log_command_usage '<update_tomorrow>', false, Time.now - start_time
    end

    def update_left_schedule(query, chat, group)
      start_time = Time.now
      logger.debug "Updating left pairs schedule of group #{group}..."

      text =
        if Date.today.sunday?
          'Сегодня воскресенье, отдыхай!'
        else
          department = parser.fetch_all_groups.find { |_, g| g.key? group }.first
          group_info = { department: department, group: group }
          schedule = parser.fetch_schedule group_info
          unless schedule
            send_update_error_message chat.tg_id
            report("Failed to fetch schedule for #{group_info}", photo: make_photo.call, log: 20)
            chat.log_command_usage '<update_week>', false, Time.now - start_time
            return
          end

          left_schedule = Schedule.from_raw(schedule).left
          if left_schedule.nil? || left_schedule.all_empty?
            'Сегодня больше нет пар!'
          else
            left_schedule.format
          end
        end

      Session[chat].tap do
        it.state = Session::State::DEFAULT
        it.save
      end

      rm = { inline_keyboard: make_update_inline_keyboard('update_left', group) }.to_json
      successful =
        unless edit_message_text(message: query.message, text: text, parse_mode: 'Markdown', reply_markup: rm)
          handle_old_query_error chat do
            bot.api.answer_callback_query(callback_query_id: query.id, text: 'Ничего не изменилось')
          end
        end
      chat.log_command_usage '<update_left>', successful, Time.now - start_time
    rescue StandardError => e
      send_update_error_message query.message.chat.id
      "Failed to update week schedule message: #{e.detailed_message}".tap do
        report it, backtrace: e.backtrace.join("\n"), log: 20
        logger.error it
        logger.error e.backtrace.join("\n\t")
      end
      chat.log_command_usage '<update_week>', false, Time.now - start_time
    end

    def handle_old_query_error(chat, &block)
      block&.call
      true
    rescue Telegram::Bot::Exceptions::ResponseError => e
      if e.error_code == 400 && e.message =~ /query is too old/i
        logger.warn "Someone's very fast, but query is too old: @#{chat.username} ##{chat.tg_id}"
        return false
      end

      raise e
    end

    def update_teacher_schedule(query, chat, teacher_id)
      start_time = Time.now
      teacher_name = parser.fetch_teachers.find { |_, v| v == teacher_id }.first
      logger.debug "Updating teacher schedule of teacher #{teacher_name}"

      schedule = parser.fetch_teacher_schedule teacher_id, teacher_name
      file_path = ImageGenerator.image_path teacher_id: teacher_id
      make_photo = -> { Faraday::UploadIO.new file_path, 'image/png' }

      Session[chat].tap do
        it.state = Session::State::DEFAULT
        it.save
      end

      unless schedule
        send_update_error_message chat.tg_id
        report("Failed to fetch schedule for #{group_info}", photo: make_photo.call, log: 20)
        chat.log_command_usage '<update_week>', false, Time.now - start_time
        return
      end

      successful = edit_message_photo(
        message: query.message,
        photo: make_photo.call,
        reply_markup: { inline_keyboard: make_update_inline_keyboard('update_teacher', teacher_id) }.to_json
      )
      chat.log_command_usage '<update_teacher>', successful, Time.now - start_time
    rescue StandardError => e
      send_update_error_message query.message.chat.id
      "Failed to update teacher schedule message: #{e.detailed_message}".tap do
        report it, backtrace: e.backtrace.join("\n"), log: 20
        logger.error it
        logger.error e.backtrace.join("\n\t")
      end
      chat.log_command_usage '<update_teacher>', false, Time.now - start_time
    end

    def send_update_error_message(chat_id)
      send_message(chat_id: chat_id, text: 'Не удалось обновить расписание, попробуйте позже', reply_markup: :default)
    end

    def edit_message_text(message:, text:, **kwargs)
      bot.api.edit_message_text(chat_id: message.chat.id, message_id: message.message_id, text: text, **kwargs)
      true
    rescue Telegram::Bot::Exceptions::ResponseError => e
      case e.error_code
      when 400
        case e.message
        when /message is not modified/i then return false
        end
      end

      send_message(chat_id: message.chat.id, text: 'Не удалось обновить сообщение')
      chat = Chat.find_by tg_id: message.chat.id
      log_error chat, e, place: 'Bot#edit_message_photo'
      false
    end

    def edit_message_photo(message:, photo:, **kwargs)
      bot.api.edit_message_media(
        chat_id: message.chat.id,
        message_id: message.message_id,
        media: { type: 'photo', media: 'attach://file' }.to_json,
        file: photo,
        **kwargs
      )
      true
    rescue Telegram::Bot::Exceptions::ResponseError => e
      case e.error_code
      when 400
        case e.message
        when /message is not modified/i
          bot.api.edit_message_caption(
            chat_id: message.chat.id,
            message_id: message.message_id,
            caption: 'Ничего не изменилось', **kwargs
          )
          return true
        end
      end

      send_message(chat_id: message.chat.id, text: 'Не удалось обновить сообщение')
      chat = Chat.find_by tg_id: message.chat.id
      log_error chat, e, place: 'Bot#edit_message_photo'
      false
    end

    def make_update_inline_keyboard(*args)
      [[{ text: 'Обновить', callback_data: args.join("\n") }]]
    end
  end
end
