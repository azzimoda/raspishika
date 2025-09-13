# frozen_string_literal: true

require 'fuzzy_match'

require_relative '../schedule'

module Raspishika
  class Bot
    private

    def send_week_schedule(message, chat, session, quick: nil)
      session.state = Session::State::DEFAULT
      session.save

      group_info =
        if quick
          logger.debug "Quick schedule: #{quick.inspect}"
          quick
        else
          unless chat.department && chat.group
            bot.api.send_message(chat_id: chat.tg_id, text: 'Группа не выбрана')
            return configure_group message, chat, session
          end
          chat.group_info
        end

      sent_message = send_loading_message chat.tg_id

      schedule = parser.fetch_schedule group_info

      file_path = ImageGenerator.image_path(group_info: group_info)
      make_photo = -> { Faraday::UploadIO.new(file_path, 'image/png') }
      reply_markup = default_reply_markup chat.tg_id

      send_photo(chat_id: chat.tg_id, photo: make_photo.call, reply_markup: reply_markup)
      unless schedule
        bot.api.send_message(
          chat_id: chat.tg_id,
          text: 'Не удалось обновить расписание, *картинка может быть не актуальной!* Попробуйте позже.',
          parse_mode: 'Markdown',
          reply_markup: reply_markup
        )
        report("Failed to fetch schedule for #{group_info}", photo: make_photo.call, log: 20)
      end
      bot.api.delete_message(chat_id: chat.tg_id, message_id: sent_message.message_id)
      throw :fail, true unless schedule
    end

    def send_tomorrow_schedule(message, chat, session)
      session.state = Session::State::DEFAULT
      session.save

      unless chat.department && chat.group
        bot.api.send_message(chat_id: chat.tg_id, text: 'Группа не выбрана')
        return configure_group message, chat, session
      end

      sent_message = send_loading_message chat.tg_id
      schedule = parser.fetch_schedule chat.group_info
      day_index = Date.today.sunday? ? 0 : 1
      tomorrow_schedule = schedule && Schedule.from_raw(schedule).day(day_index)
      text =
        if tomorrow_schedule.nil? || tomorrow_schedule.all_empty?
          'Завтра нет пар!'
        else
          tomorrow_schedule.format
        end

      bot.api.send_message(
        chat_id: chat.tg_id,
        text: text,
        parse_mode: 'Markdown',
        reply_markup: default_reply_markup(chat.tg_id)
      )
      bot.api.delete_message(chat_id: chat.tg_id, message_id: sent_message.message_id)
    end

    def send_left_schedule(message, chat, session)
      session.state = Session::State::DEFAULT
      session.save

      unless chat.department && chat.group
        bot.api.send_message(chat_id: chat.tg_id, text: 'Группа не выбрана')
        return configure_group message, chat, session
      end

      reply_markup = default_reply_markup chat.tg_id

      if Date.today.sunday?
        bot.api.send_message(chat_id: chat.tg_id, text: 'Сегодня воскресенье, отдыхай!', reply_markup: reply_markup)
        return
      end

      sent_message = send_loading_message chat.tg_id
      schedule = parser.fetch_schedule chat.group_info
      left_schedule = schedule && Schedule.from_raw(schedule).left
      text =
        if left_schedule.nil? || left_schedule.all_empty?
          'Сегодня больше нет пар!'
        else
          left_schedule.format
        end

      bot.api.send_message(chat_id: chat.tg_id, text: text, parse_mode: 'Markdown', reply_markup: reply_markup)
      bot.api.delete_message(chat_id: chat.tg_id, message_id: sent_message.message_id)
    end

    def ask_for_quick_schedule_type(_message, chat, session)
      session.state = Session::State::SELECTING_QUICK_SCHEDULE
      session.save

      bot.api.send_message(
        chat_id: chat.tg_id,
        text: 'Какое расписание?',
        reply_markup: {
          keyboard: [['Отмена'], [LABELS[:other_group], LABELS[:teacher]]],
          resize_keyboard: true
        }.to_json
      )
    end

    def ask_for_teacher(_message, chat, session)
      session.state = Session::State::SELECTING_TEACHER
      session.save

      bot.api.send_message(
        chat_id: chat.tg_id,
        text: 'Пришли полное имя или фамилию преподавателя',
        reply_markup: {
          keyboard: [['Отмена']] + chat.recent_teachers.order(created_at: :desc).map(&:name).each_slice(2).to_a,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    end

    def reask_for_teacher(_message, chat, session, name)
      logger.info "Reasking for teacher with name #{name.inspect}..."
      teachers = FuzzyMatch.new(parser.fetch_teachers.keys).find_all(name).first 6
      logger.debug "Found teachers: #{teachers.inspect}"

      session.state = Session::State::SELECTING_TEACHER
      session.save

      bot.api.send_message(
        chat_id: chat.tg_id,
        text: 'Выбери преподавателя',
        reply_markup: {
          keyboard: [['Отмена']] + teachers.each_slice(2).to_a,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    end

    def send_teacher_schedule(message, chat, session)
      sent_message = send_loading_message chat.tg_id

      teacher_name = validate_teacher_name message.text
      logger.debug "Teacher name: #{teacher_name.inspect}"
      teachers = parser.fetch_teachers
      teacher_id = teachers[teacher_name]
      logger.debug "Teacher id: #{teacher_id.inspect}"
      schedule = parser.fetch_teacher_schedule teacher_id, teacher_name

      file_path = ImageGenerator.image_path teacher_id: teacher_id
      make_photo = -> { Faraday::UploadIO.new file_path, 'image/png' }
      reply_markup = default_reply_markup chat.tg_id

      chat.add_recent_teacher teacher_name
      session.state = Session::State::DEFAULT
      session.save

      send_photo chat_id: chat.tg_id, photo: make_photo.call, reply_markup: reply_markup
      unless schedule
        bot.api.send_message(
          chat_id: chat.tg_id,
          text: 'Не удалось обновить расписание, *картинка может быть не актуальной!* Попробуйте позже.',
          parse_mode: 'Markdown',
          reply_markup: reply_markup
        )
        report("Failed to fetch schedule for #{teacher_name} (#{teacher_id})", photo: make_photo.call, log: 20)
      end
      bot.api.delete_message(chat_id: chat.tg_id, message_id: sent_message.message_id)
      throw :fail, true unless schedule
    end

    def validate_teacher_name(name)
      names = parser.fetch_teachers.keys
      names.find { it.downcase == name.strip.downcase } ||
        FuzzyMatch.new(names).find_all(name).then { it.first if it.one? }
    end

    def send_loading_message(chat_id)
      bot.api.send_message(
        chat_id: chat_id,
        text: 'Загружаю...',
        reply_markup: { remove_keyboard: true }.to_json
      )
    end
  end
end
