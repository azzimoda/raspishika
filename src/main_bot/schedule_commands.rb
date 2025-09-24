# frozen_string_literal: true

require 'json'
require 'fuzzy_match'

require_relative '../schedule'

module Raspishika
  class Bot
    private

    def send_week_schedule(message, chat, session, quick: nil)
      session.default!
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
      make_photo = -> { Faraday::UploadIO.new(ImageGenerator.image_path(group_info: group_info), 'image/png') }

      kb = make_update_inline_keyboard 'update_week', group_info[:group]
      send_photo(chat_id: chat.tg_id, photo: make_photo.call, reply_markup: { inline_keyboard: kb }.to_json)
      send_message(chat_id: chat.tg_id, text: "Расписание группы: *#{group_info[:group]}*", parse_mode: 'Markdown',
                   reply_markup: :default)
      unless schedule
        bot.api.send_message(
          chat_id: chat.tg_id,
          text: 'Не удалось обновить расписание, *картинка может быть не актуальной!* Попробуйте позже.',
          parse_mode: 'Markdown',
          reply_markup: :default
        )
        report("Failed to fetch schedule for #{group_info}", photo: make_photo.call, log: 20)
      end
      bot.api.delete_message(chat_id: chat.tg_id, message_id: sent_message.message_id)
      throw :fail, true unless schedule
    end

    def send_tomorrow_schedule(message, chat, session)
      session.default!
      session.save

      unless chat.department && chat.group
        send_message(chat_id: chat.tg_id, text: 'Группа не выбрана')
        return configure_group message, chat, session
      end

      schedule = parser.fetch_schedule chat.group_info
      tomorrow_schedule = schedule && Schedule.from_raw(schedule).day(Date.today.sunday? ? 0 : 1)
      text = tomorrow_schedule.nil? || tomorrow_schedule.all_empty? ? 'Завтра нет пар!' : tomorrow_schedule.format
      rm = { inline_keyboard: make_update_inline_keyboard('update_tomorrow', chat.group) }.to_json
      send_message(chat_id: chat.tg_id, text: text, parse_mode: 'Markdown', reply_markup: rm)
    end

    def send_left_schedule(message, chat, session)
      session.default!
      session.save

      unless chat.department && chat.group
        send_message(chat_id: chat.tg_id, text: 'Группа не выбрана')
        return configure_group message, chat, session
      end

      if Date.today.sunday?
        rm = { inline_keyboard: make_update_inline_keyboard('update_left', chat.group) }.to_json
        send_message(chat_id: chat.tg_id, text: 'Сегодня воскресенье, отдыхай!', reply_markup: rm)
        return
      end

      schedule = parser.fetch_schedule chat.group_info
      left_schedule = schedule && Schedule.from_raw(schedule).left
      text =
        if left_schedule.nil? || left_schedule.all_empty?
          'Сегодня больше нет пар!'
        else
          left_schedule.format
        end

      send_message(chat_id: chat.tg_id, text: text, parse_mode: 'Markdown',
                   reply_markup: { inline_keyboard: make_update_inline_keyboard('update_left', chat.group) }.to_json)
    end

    def ask_for_quick_schedule_type(_message, chat, session)
      session.quick_schedule!
      session.save

      bot.api.send_message(
        chat_id: chat.tg_id,
        text: 'Какое расписание?',
        reply_markup: {
          keyboard: [['Отмена'], [LABELS[:other_group], LABELS[:teacher]]],
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    end

    def ask_for_teacher(_message, chat, session)
      session.selecting_teacher!
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

      session.selecting_teacher!
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
      loading_message = send_loading_message chat.tg_id

      teacher_name = validate_teacher_name message.text
      logger.debug "Teacher name: #{teacher_name.inspect}"

      chat.add_recent_teacher teacher_name
      session.default!
      session.save

      teacher_id = parser.fetch_teachers[teacher_name]
      schedule = parser.fetch_teacher_schedule teacher_id, teacher_name
      make_photo = -> { Faraday::UploadIO.new(ImageGenerator.image_path(teacher_id: teacher_id), 'image/png') }

      send_photo(chat_id: chat.tg_id, photo: make_photo.call,
                 reply_markup: { inline_keyboard: make_update_inline_keyboard('update_teacher', teacher_id) }.to_json)
      send_message(chat_id: chat.tg_id, text: "Расписание преподавателя: *#{teacher_name}*", reply_markup: :default,
                   parse_mode: 'Markdown')
      bot.api.delete_message(chat_id: chat.tg_id, message_id: loading_message.message_id)
      return if schedule

      bot.api.send_message(
        chat_id: chat.tg_id,
        text: 'Не удалось обновить расписание, *картинка может быть не актуальной!* Попробуйте позже.',
        parse_mode: 'Markdown',
        reply_markup: :default
      )
      report("Failed to fetch schedule for #{teacher_name} (#{teacher_id})", photo: make_photo.call, log: 20)
      throw :fail, true
    end

    def validate_teacher_name(name)
      names = parser.fetch_teachers.keys
      names.find { it.downcase == name.strip.downcase } ||
        FuzzyMatch.new(names).find_all(name).then { it.first if it.one? }
    end

    def send_loading_message(chat_id)
      bot.api.send_message(chat_id: chat_id, text: 'Загружаю...', reply_markup: { remove_keyboard: true }.to_json)
    end
  end
end
