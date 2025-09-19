# frozen_string_literal: true

module Raspishika
  class Bot
    def handle_callback_query(query)
      args = query.data.split "\n"

      msg_chat = query.message.chat
      msg_from = query.from
      msg_end = "@#{msg_from.username} #{msg_from.full_name} <callback> #{args.join(' ; ')}"
      if msg_chat.type == 'private'
        logger.debug "[#{msg_chat.id}] #{msg_end}"
      else
        logger.debug "[#{msg_chat.id} @#{msg_chat.username} #{msg_chat.title}] #{msg_end}"
      end

      chat = Chat.find_by tg_id: query.message.chat.id

      case args[0]
      when 'update_week' then update_week_schedule(query, chat, *args[1..])
      when 'update_teacher' then update_teacher_schedule(query, chat, *args[1..])
      else logger.warn "Unexpected callback query data: #{query.data.inspect}"
      end
    end

    def update_week_schedule(query, chat, group)
      start_time = Time.now
      logger.debug "Updating schedule of group #{group}"

      deps = parser.fetch_all_groups
      department = deps.find { |_, g| g.key? group }.first
      group_info = { department: department, group: group }
      schedule = parser.fetch_schedule group_info
      file_path = ImageGenerator.image_path group_info: group_info
      make_photo = -> { Faraday::UploadIO.new file_path, 'image/png' }

      Session[chat].tap do
        it.state = Session::State::DEFAULT
        it.save
      end

      unless schedule
        bot.api.send_message(
          chat_id: chat.tg_id,
          text: 'Не удалось обновить расписание, попробуйте позже.',
          reply_markup: default_reply_markup(chat.tg_id)
        )
        report("Failed to fetch schedule for #{group_info}", photo: make_photo.call, log: 20)
        return
      end

      successful = edit_message_photo(
        message: query.message,
        photo: make_photo.call,
        reply_markup: { inline_keyboard: make_update_inline_keyboard('update_week', group) }.to_json
      )
      chat.log_command_usage '<update_week>', successful, Time.now - start_time
    rescue StandardError => e
      send_message(chat_id: query.message.chat.id, text: 'Не удалось обновить сообщение')
      "Failed to update week schedule message: #{e.detailed_message}".tap do
        report it, backtrace: e.backtrace.join("\n"), log: 20
        logger.error it
        logger.error e.backtrace.join("\n\t")
      end
      chat.log_command_usage '<update_week>', false, Time.now - start_time
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
        bot.api.send_message(
          chat_id: chat.tg_id,
          text: 'Не удалось обновить расписание, попробуйте позже.',
          reply_markup: default_reply_markup(chat.tg_id)
        )
        report("Failed to fetch schedule for #{group_info}", photo: make_photo.call, log: 20)
        return
      end

      successful = edit_message_photo(
        message: query.message,
        photo: make_photo.call,
        reply_markup: { inline_keyboard: make_update_inline_keyboard('update_teacher', teacher_id) }.to_json
      )
      chat.log_command_usage '<update_teacher>', successful, Time.now - start_time
    rescue StandardError => e
      send_message(chat_id: query.message.chat.id, text: 'Не удалось обновить сообщение')
      "Failed to update week schedule message: #{e.detailed_message}".tap do
        report it, backtrace: e.backtrace.join("\n"), log: 20
        logger.error it
        logger.error e.backtrace.join("\n\t")
      end
      chat.log_command_usage '<update_teacher>', false, Time.now - start_time
    end

    def edit_message_photo(message:, photo:, **kwrags)
      bot.api.edit_message_media(
        chat_id: message.chat.id,
        message_id: message.message_id,
        media: { type: 'photo', media: 'attach://file' }.to_json,
        file: photo,
        **kwrags
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
            caption: 'Ничего не изменилось', **kwrags
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
