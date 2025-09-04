# frozen_string_literal: true

require 'fuzzy_match'

require_relative '../schedule'

module Raspishika
  class Bot
    private

    def send_week_schedule(message, user, quick: nil)
      user.state = User::State::DEFAULT

      group_info =
        if quick
          logger.debug "Quick schedule: #{quick.inspect}"
          quick
        else
          unless user.department_name && user.group_name
            bot.api.send_message(chat_id: user.id, text: 'Группа не выбрана')
            return configure_group(message, user)
          end

          user.group_info
        end

      sent_message = send_loading_message user.id

      schedule = parser.fetch_schedule group_info

      file_path = ImageGenerator.image_path(group_info: group_info)
      make_photo = -> { Faraday::UploadIO.new(file_path, 'image/png') }
      reply_markup = default_reply_markup user.id

      bot.api.send_photo(chat_id: user.id, photo: make_photo.call, reply_markup: reply_markup)
      if schedule
        user.push_command_usage command: '/week', ok: true
      else
        user.push_command_usage command: '/week', ok: false
        bot.api.send_message(
          chat_id: user.id,
          text: 'Не удалось обновить расписание, *картинка может быть не актуальной!* Попробуйте позже.',
          parse_mode: 'Markdown',
          reply_markup: reply_markup
        )
        report("Failed to fetch schedule for #{group_info}", photo: make_photo.call, log: 20)
      end
      bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)
    rescue StandardError => e
      user.push_command_usage command: '/week', ok: false
      raise e
    end

    def send_tomorrow_schedule(message, user)
      user.state = User::State::DEFAULT

      unless user.department_name && user.group_name
        bot.api.send_message(chat_id: user.id, text: 'Группа не выбрана')
        return configure_group(message, user)
      end

      sent_message = send_loading_message user.id
      schedule = parser.fetch_schedule user.group_info
      day_index = Date.today.sunday? ? 0 : 1
      tomorrow_schedule = schedule && Schedule.from_raw(schedule).day(day_index)
      text =
        if tomorrow_schedule.nil? || tomorrow_schedule.all_empty?
          'Завтра нет пар!'
        else
          tomorrow_schedule.format
        end

      bot.api.send_message(
        chat_id: user.id,
        text: text,
        parse_mode: 'Markdown',
        reply_markup: default_reply_markup(user.id)
      )
      bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)

      user.push_command_usage command: '/tomorrow'
    rescue StandardError => e
      user.push_command_usage command: '/tomorrow', ok: false
      raise e
    end

    def send_left_schedule(message, user)
      user.state = User::State::DEFAULT

      unless user.department_name && user.group_name
        bot.api.send_message(chat_id: user.id, text: 'Группа не выбрана')
        return configure_group(message, user)
      end

      reply_markup = default_reply_markup user.id

      if Date.today.sunday?
        user.push_command_usage command: '/left'
        bot.api.send_message(chat_id: user.id, text: 'Сегодня воскресенье, отдыхай!', reply_markup: reply_markup)
        return
      end

      sent_message = send_loading_message user.id
      schedule = parser.fetch_schedule user.group_info
      left_schedule = schedule && Schedule.from_raw(schedule).left
      text =
        if left_schedule.nil? || left_schedule.all_empty?
          'Сегодня больше нет пар!'
        else
          left_schedule.format
        end

      bot.api.send_message(chat_id: user.id, text: text, parse_mode: 'Markdown', reply_markup: reply_markup)
      bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)

      user.push_command_usage command: '/left'
    rescue StandardError => e
      user.push_command_usage command: '/left', ok: false
      raise e
    end

    def ask_for_quick_schedule_type(_message, user)
      user.state = User::State::SELECTING_QUICK_SCHEDULE
      bot.api.send_message(
        chat_id: user.id,
        text: 'Какое расписание?',
        reply_markup: {
          keyboard: [['Отмена'], [LABELS[:other_group], LABELS[:teacher]]],
          resize_keyboard: true
        }.to_json
      )
    rescue StandardError => e
      user.push_command_usage command: '/teacher_schedule', ok: false
      raise e
    end

    def ask_for_teacher(_message, user)
      bot.api.send_message(
        chat_id: user.id,
        text: 'Пришли полное имя или фамилию преподавателя',
        reply_markup: {
          keyboard: [['Отмена']] + user.recent_teachers.each_slice(2).to_a,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
      user.state = User::State::SELECTING_TEACHER
    rescue StandardError => e
      user.push_command_usage command: '/teacher_schedule', ok: false
      raise e
    end

    def reask_for_teacher(_message, user, name)
      logger.info "Reasking for teacher with name #{name.inspect}..."
      teachers = FuzzyMatch.new(parser.fetch_teachers_names.keys).find_all(name).first 6
      logger.debug "Found teachers: #{teachers.inspect}"

      bot.api.send_message(
        chat_id: user.id,
        text: 'Выбери преподавателя',
        reply_markup: {
          keyboard: [['Отмена']] + teachers.each_slice(2).to_a,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
      user.state = User::State::SELECTING_TEACHER
    rescue StandardError => e
      user.push_command_usage command: '/teacher_schedule', ok: false
      raise e
    end

    def send_teacher_schedule(message, user)
      sent_message = send_loading_message user.id

      teacher_name = validate_teacher_name message.text
      logger.debug "Teacher name: #{teacher_name.inspect}"
      teachers = parser.fetch_teachers_names
      teacher_id = teachers[teacher_name]
      logger.debug "Teacher id: #{teacher_id.inspect}"
      schedule = parser.fetch_teacher_schedule teacher_id, teacher_name

      file_path = ImageGenerator.image_path teacher_id: teacher_id
      make_photo = -> { Faraday::UploadIO.new file_path, 'image/png' }
      reply_markup = default_reply_markup user.id

      user.push_recent_teacher teacher_name
      user.state = User::State::DEFAULT

      bot.api.send_photo(chat_id: user.id, photo: make_photo.call, reply_markup: reply_markup)
      if schedule
        user.push_command_usage command: '/teacher_schedule', ok: true
      else
        user.push_command_usage command: '/teacher_schedule', ok: false
        bot.api.send_message(
          chat_id: user.id,
          text: 'Не удалось обновить расписание, *картинка может быть не актуальной!* Попробуйте позже.',
          parse_mode: 'Markdown',
          reply_markup: reply_markup
        )
        report("Failed to fetch schedule for #{teacher_name} (#{teacher_id})", photo: make_photo.call, log: 20)
      end
      bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)
    rescue StandardError => e
      user.push_command_usage command: '/teacher_schedule', ok: false
      raise e
    end

    def validate_teacher_name(name)
      names = parser.fetch_teachers_names.keys
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
