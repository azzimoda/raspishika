module Raspishika
  class Bot
    LONG_CACHE_TIME = 24*60*60 # 24 hours

    START_MESSAGE = <<~MARKDOWN
    Привет! Используй /set_group чтобы задать группу, затем используйте команды /week, /tomorrow и \
    /left, чтобы получать расписание.
    Также можно быстро посмотреть расписание другой группы с помощью /quick_schedule, и настроить \
    автоматическую рассылку рассылку с помощью /configure_sending.
    MARKDOWN

    HELP_MESSAGE = <<~MARKDOWN
    Доступные команды:
  
    - /start — Запуск бота
    - /help — Помощь
    - /left — Оставшиеся пары
    - /tomorrow — Расписание на завтра
    - /week — Расписание на неделю
    - /quick_schedule — Быстрое расписание другой группы
    - /configure_sending — Войти в меню настройки рассылок
    - /configure_daily_sending — Настроить ежедневную рассылку
    - /daily_sending_off — Выключить ежедневную рассылку
    - /pair_sending_on — Включить рассылку перед парами
    - /pair_sending_off — Выключить рассылку перед парами
    - /set_group — Изменить свою группу
    - /cancel — Отменить текущее действие
    - /stop — Остановить бота и удалить данные о себе
  
    Вы также можете использовать кнопки клавиатуры для быстрого доступа к основным функциям.
    MARKDOWN
  
    def start_message(message, user)
      bot.api.send_message(
        chat_id: message.chat.id,
        text: START_MESSAGE,
        reply_markup: default_reply_markup(user.id)
      )
  
      unless user.statistics[:start]
        user.statistics[:start] = Time.now
        msg = "New user: #{message.chat.id}" \
          " (@#{message.from.username}, #{message.from.first_name} #{message.from.last_name})"
        report msg
        logger.debug msg
      end
    end
  
    def help_message(message, user)
      bot.api.send_message(
        chat_id: message.chat.id,
        text: HELP_MESSAGE,
        reply_markup: default_reply_markup(user.id)
      )
    end
  
    def stop(message, user)
      User.delete user
  
      bot.api.send_message(
        chat_id: messag.chat.id,
        text:
          "Ваши данные были удалены, и Вы больше не будете получать рассылки от этого бота.\n" \
          "Спасибо за использование бота!",
        reply_markup: {remove_keyboard: true}.to_json
      )
    end
  
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
  
    def send_week_schedule(_message, user, quick: nil)
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

      sent_message = send_loading_message user.id

      schedule = Cache.fetch(:"schedule_#{group_info[:sid]}_#{group_info[:gr]}") do
        parser.fetch_schedule group_info
      end

      file_path = ImageGenerator.image_path(**group_info)
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
  
    def debug_command(message, user)
      return unless ENV['DEBUG_CM']
  
      debug_command_name = message.text.split(' ').last
      logger.info "Calling test #{debug_command_name}..."
      unless DebugCommands.respond_to? debug_command_name
        logger.warn "Test #{debug_command_name} not found"
        bot.api.send_message(
          chat_id: message.chat.id,
          text:
            "Тест `#{debug_command_name}` не найден.\n\n" \
            "Доступные тесты: #{DebugCommands.methods.join(', ')}",
          reply_markup: default_reply_markup(user.id)
        )
        return
      end
  
      DebugCommands.send(debug_command_name, bot: self, user:, message:)
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
  
    private

    def default_reply_markup id
      id.to_s.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
    end

    def send_loading_message id
      bot.api.send_message(
        chat_id: id,
        text: "Загружаю расписание...",
        reply_markup: {remove_keyboard: true}.to_json
      )
    end
  end
end
