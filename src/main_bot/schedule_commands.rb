require_relative '../schedule'

module Raspishika
  class Bot
    private

    def send_week_schedule(_message, user, quick: nil)
      get_group_info = lambda do
        group_info = if quick
          quick
        else
          unless user.department && user.group
            bot.api.send_message(chat_id: user.id, text: "Группа не выбрана")
            return configure_group(_message, user)
          end

          unless user.department_name
            bot.api.send_message(
              chat_id: user.id,
              text:
                "В связи с техническими проблемами нужно выбрать группу заново. " \
                "Это нужно сделать один раз, больше такого не повторится."
            )
            return configure_group(_message, user)
          end

          user.group_info
        end
      end

      sent_message = send_loading_message user.id

      schedule = parser.fetch_schedule get_group_info.call

      file_path = ImageGenerator.image_path(**get_group_info.call)
      make_photo = -> { Faraday::UploadIO.new(file_path, 'image/png') }
      reply_markup = default_reply_markup user.id

      bot.api.send_photo(chat_id: user.id, photo: make_photo.call, reply_markup:)
      unless schedule
        user.push_command_usage command: _message.text, ok: false

        bot.api.send_message(
          chat_id: user.id,
          text:
            "Не удалось обновить расписание, *картинка может быть не актуальной!*" \
            " Попробуйте позже.",
          parse_mode: 'Markdown',
          reply_markup:
        )
        report("Failed to fetch schedule for #{group_info}", photo: make_photo.call, log: 20)
      else
        user.push_command_usage command: _message.text, ok: true
      end
      bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)
    end

    def send_tomorrow_schedule(_message, user)
      unless user.department && user.group
        bot.api.send_message(chat_id: user.id, text: "Группа не выбрана")
        return configure_group(_message, user)
      end

      unless user.department_name
        bot.api.send_message(
          chat_id: user.id,
          text:
            "В связи с техническими проблемами нужно выбрать группу заново. " \
            "Это нужно сделать один раз, больше такого не повторится."
        )
        return configure_group(_message, user)
      end

      sent_message = send_loading_message user.id
      schedule = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
        parser.fetch_schedule user.group_info
      end
      day_index = Date.today.sunday? ? 0 : 1
      tomorrow_schedule = schedule && Schedule.from_raw(schedule).day(day_index)
      text = if tomorrow_schedule.nil? || tomorrow_schedule.all_empty?
        "Завтра нет пар!"
      else
        tomorrow_schedule.format
      end

      bot.api.send_message(
        chat_id: user.id,
        text:,
        parse_mode: 'Markdown',
        reply_markup: default_reply_markup(user.id)
      )
      bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)

      user.push_command_usage command: _message.text
    end

    def send_left_schedule(_message, user)
      unless user.department && user.group
        bot.api.send_message(chat_id: user.id, text: "Группа не выбрана")
        return configure_group(_message, user)
      end

      unless user.department_name
        bot.api.send_message(
          chat_id: user.id,
          text:
            "В связи с техническими проблемами нужно выбрать группу заново. " \
            "Это нужно сделать один раз, больше такого не повторится."
        )
        return configure_group(_message, user)
      end

      reply_markup = default_reply_markup user.id

      if Date.today.sunday?
        user.push_command_usage command: _message.text
        bot.api.send_message(chat_id: user.id, text: "Сегодня воскресенье, отдыхай!", reply_markup:)
        return
      end

      sent_message = send_loading_message user.id
      schedule = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
        parser.fetch_schedule user.group_info
      end
      left_schedule = schedule && Schedule.from_raw(schedule).left
      text = if left_schedule.nil? || left_schedule.all_empty?
        "Сегодня больше нет пар!"
      else
        left_schedule.format
      end

      bot.api.send_message(chat_id: user.id, text:, parse_mode: 'Markdown', reply_markup:)
      bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)

      user.push_command_usage command: _message.text
    end

    def send_loading_message chat_id
      bot.api.send_message(
        chat_id:,
        text: "Загружаю...",
        reply_markup: {remove_keyboard: true}.to_json
      )
    end
  end
end