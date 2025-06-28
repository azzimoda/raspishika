module Raspishika
  class Bot
    private

    def configure_group(message, user, quick: false)
      departments = Cache.fetch(:departments, expires_in: LONG_CACHE_TIME) { parser.fetch_departments }

      unless departments&.any?
        user.push_command_usage command: message.text, ok: false

        bot.api.send_message(
          chat_id: user.id,
          text: "Не удалось загрузить отделения",
          reply_markup: default_reply_markup(user.id)
        )

        return
      end

      user.departments = departments.keys
      user.state = quick ? :select_department_quick : :select_department
      user.push_command_usage command: message.text, ok: true

      bot.api.send_message(
        chat_id: user.id,
        text: "Выбери отделение",
        reply_markup: {
          keyboard: [["Отмена"]] + departments.keys.each_slice(2).to_a,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    end

    def select_department(message, user)
      departments = Cache.fetch(:departments, expires_in: LONG_CACHE_TIME) { parser.fetch_departments }  
      groups = Cache.fetch(:"groups_#{message.text.downcase}", expires_in: LONG_CACHE_TIME) do
        parser.fetch_groups departments[message.text]
      end
      unless groups&.any?
        user.push_command_usage command: message.text, ok: false

        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Не удалось загрузить группы для этого отделения",
          reply_markup: default_reply_markup(user.id)
        )
        return
      end

      user.department_url = departments[message.text]
      user.department_name_temp = message.text
      user.groups = groups
      user.state = user.state.end_with?('quick') ? :select_group_quick : :select_group
      user.push_command_usage command: message.text, ok: true

      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Выбери группу",
        reply_markup: {
          keyboard: [["Отмена"]] + groups.keys.each_slice(2).to_a,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    end

    def select_group(message, user)
      group_info = user.groups[message.text]

      user.groups = {}

      if user.state.end_with? 'quick'
        send_week_schedule(
          message,
          user,
          quick: group_info.merge(department: user.department_name_temp, group: message.text)
        )
      else
        user.department = group_info[:sid]
        user.department_name = user.department_name_temp
        user.group = group_info[:gr]
        user.group_name = message.text

        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Теперь #{message.chat.id > 0 ? 'ты' : 'вы'} в группе #{message.text}",
          reply_markup: default_reply_markup(user.id)
        )
      end
      user.state = :default
    end

    def configure_sending(_message, user)
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

      user.push_command_usage command: _message.text

      pair_sending_label = user.pair_sending ? LABELS[:pair_sending_off] : LABELS[:pair_sending_on]
      bot.api.send_message(
        chat_id: user.id,
        text: "Какую рассылку настроить?",
        reply_markup: {
          keyboard: [["Отмена"], ["Ежедневная рассылка", pair_sending_label]],
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
      user.state = :select_senging_type
    end

    def configure_daily_sending(message, user)
      user.state = :configure_daily_sending
      user.push_command_usage command: message.text

      current_configuration = user.daily_sending ? " (сейчас: `#{user.daily_sending}`)" : ""
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Выберите время для ежедневной рассылки#{current_configuration}\nНапример: `7:00`",
        parse_mode: 'Markdown',
        reply_markup: {
          keyboard: [["Отмена"], ["Отключить"]],
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    end

    def set_daily_sending(message, user)
      user.daily_sending = Time.parse(message.text).strftime('%H:%M')
      user.state = :default
      user.push_command_usage command: message.text

      bot.api.send_message(
        chat_id: user.id,
        text: "Ежедневная рассылка настроена на `#{user.daily_sending}`",
        parse_mode: 'Markdown',
        reply_markup: default_reply_markup(user.id)
      )
    end

    def disable_daily_sending(message, user)
      user.daily_sending = nil
      user.state = :default
      user.push_command_usage command: message.text

      bot.api.send_message(
        chat_id: user.id,
        text: "Ежедневная рассылка отключена",
        reply_markup: default_reply_markup(user.id)
      )
    end

    def enable_pair_sending(message, user)
      user.pair_sending = true
      user.state = :default
      user.push_command_usage command: message.text

      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Рассылка за 15 минут перед парами включена",
        reply_markup: default_reply_markup(user.id)
      )
    end

    def disable_pair_sending(message, user)
      user.pair_sending = false
      user.state = :default
      user.push_command_usage command: message.text

      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Рассылка за 15 минут перед парами выключена",
        reply_markup: default_reply_markup(user.id)
      )
    end

    def cancel_action (message, user)
      reply_markup = default_reply_markup user.id
      case user.state
      when :default
        bot.api.send_message(chat_id: user.id, text: "Нечего отменять", reply_markup:)
      else
        user.state = :default
        bot.api.send_message(chat_id: user.id, text: "Действие отменено", reply_markup:)
      end
    end

  end
end
