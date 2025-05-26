class RaspishikaBot
  def start_message(message, user)
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Привет! Используй /set_group чтобы задать группу и кнопки ниже для других действий",
      reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
    )

    unless user.statistics[:start]
      user.statistics[:start] = Time.now
      msg = "New user: #{message.chat.id}" \
        " (@#{message.from.username}, #{message.from.first_name} #{message.from.last_name})"
      logger.debug msg
      report msg
    end
  end

  def help_message(message, user)
    bot.api.send_message(
      chat_id: message.chat.id,
      text: HELP_MESSAGE,
      reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
    )
  end

  def configure_group(message, user)
    departments = Cache.fetch(:departments, expires_in: LONG_CACHE_TIME) { parser.fetch_departments }
    if departments&.any?
      user.departments = departments.keys
      user.state = :select_department

      keyboard = [["Отмена"]] + departments.keys.each_slice(2).to_a
      bot.api.send_message(
        chat_id: user.id,
        text: "Выбери отделение",
        reply_markup: {
          keyboard: keyboard,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    else
      bot.api.send_message(
        chat_id: user.id,
        text: "Не удалось загрузить отделения",
        reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
      )
    end
  end

  def select_department(message, user)
    departments = Cache.fetch(:departments, expires_in: LONG_CACHE_TIME) { parser.fetch_departments }

    if departments&.key? message.text
      groups = Cache.fetch(:"groups_#{message.text.downcase}", expires_in: LONG_CACHE_TIME) do
        parser.fetch_groups departments[message.text]
      end
      if groups&.any?
        user.department_url = departments[message.text]
        user.department_name_temp = message.text
        user.groups = groups
        user.state = :select_group

        keyboard = [["Отмена"]] + groups.keys.each_slice(2).to_a
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Выбери группу",
          reply_markup: {
            keyboard: keyboard,
            resize_keyboard: true,
            one_time_keyboard: true
          }.to_json
        )
      else
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Не удалось загрузить группы для этого отделения",
          reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
        )
      end
    else
      user.departments = []
      user.state = :default

      logger.warn "Cached departments differ from fetched"
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Не удалось загрузить отделение",
        reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
      )
      logger.warn "Reached code supposed to be unreachable!"
      msg = "User #{message.chat.id} (#{message.from.username}) tried to select department #{message.text} but it doesn't exist"
      logger.warn msg
      report msg
    end
  end

  def select_group(message, user)
    if (group_info = user.groups[message.text])
      user.department = group_info[:sid]
      user.department_name = user.department_name_temp
      user.group = group_info[:gr]
      user.group_name = message.text

      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Теперь #{message.chat.id > 0 ? 'ты' : 'вы'} в группе #{message.text}",
        reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
      )
    else
      user.department = nil
      user.department_name = nil

      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Группа #{message.text} не найдена. Доступные группы:\n#{user.groups.keys.join(" , ")}",
        reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
      )
      logger.warn "Reached code supposed to be unreachable!"
      msg = "User #{message.chat.id} (#{message.from.username}) tried to select group #{message.text} but it doesn't exist"
      logger.warn msg
      report msg
    end

    user.groups = {}
    user.state = :default
  end

  def send_week_schedule(_message, user)
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

    sent_message = bot.api.send_message(
      chat_id: user.id,
      text: "Загружаю расписание...",
      reply_markup: {remove_keyboard: true}.to_json
    )

    schedule = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
      parser.fetch_schedule user.group_info
    end

    file_path = ImageGenerator.image_path(**user.group_info)
    make_photo = ->() { Faraday::UploadIO.new(file_path, 'image/png') }
    bot.api.send_photo(
      chat_id: user.id,
      photo: make_photo.call,
      reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
    )
    unless schedule
      bot.api.send_message(
        chat_id: user.id,
        text:
          "Не удалось обновить расписание, *картинка может быть не актуальной!* Попробуйте позже.",
          parse_mode: 'Markdown',
        reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
      )
      report("Failed to fetch schedule for #{user.group_info}", photo: make_photo.call)
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

    sent_message = bot.api.send_message(
      chat_id: user.id,
      text: "Загружаю расписание...",
      reply_markup: {remove_keyboard: true}.to_json
    )

    schedule = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
      parser.fetch_schedule user.group_info
    end

    day_index = Date.today.sunday? ? 0 : 1
    tomorrow_schedule = schedule && Schedule.from_raw(schedule).day(day_index)
    text = if tomorrow_schedule.nil? || tomorrow_schedule.all_empty?
      "Завтра нет пар!"
    else
      text = tomorrow_schedule.format
    end

    bot.api.send_message(
      chat_id: user.id,
      text:,
      parse_mode: 'Markdown',
      reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
    )
    bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)
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

    if Date.today.sunday?
      bot.api.send_message(
        chat_id: user.id,
        text: "Сегодня воскресенье, отдыхай!",
        reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json)
      return
    end

    sent_message = bot.api.send_message(
      chat_id: user.id,
      text: "Загружаю расписание...",
      reply_markup: {remove_keyboard: true}.to_json
    )

    schedule = Cache.fetch(:"schedule_#{user.department}_#{user.group}") do
      parser.fetch_schedule user.group_info
    end
    left_schedule = schedule && Schedule.from_raw(schedule).left
    text = if left_schedule.nil? || left_schedule.all_empty?
      "Сегодня больше нет пар!"
    else
      left_schedule.format
    end

    bot.api.send_message(
      chat_id: user.id,
      text:,
      parse_mode: 'Markdown',
      reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
    )
    bot.api.delete_message(chat_id: sent_message.chat.id, message_id: sent_message.message_id)
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

    keyboard = [
      ["Отмена"],
      ["Ежедневная рассылка", "#{user.pair_sending ? 'Выкл.' : 'Вкл.'} рассылку перед парами"]
    ]
    bot.api.send_message(
      chat_id: user.id,
      text: "Какую рассылку настроить?",
      reply_markup: {keyboard:, resize_keyboard: true, one_time_keyboard: true}.to_json
    )
    user.state = :select_senging_type
  end

  def configure_daily_sending(message, user)
    current_configuration = user.daily_sending ? " (сейчас: `#{user.daily_sending}`)" : ""
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Выберите время для ежедневной рассылки#{current_configuration}\nНапример: `7:00`",
      parse_mode: 'Markdown',
      reply_markup: {keyboard: [["Отмена"], ["Отключить"]], resize_keyboard: true, one_time_keyboard: true}.to_json
    )
    user.state = :configure_daily_sending
  end

  def set_daily_sending(message, user)
    fomratted_time = Time.parse(message.text).strftime('%H:%M')
    user.daily_sending = fomratted_time
    user.state = :default
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Ежедневная рассылка настроена на `#{fomratted_time}`",
      parse_mode: 'Markdown',
      reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
    )
  end

  def disable_daily_sending(message, user)
    user.daily_sending = nil
    user.state = :default
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Ежедневная рассылка отключена",
      reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
    )
  end

  def enable_pair_sending(message, user)
    user.pair_sending = true
    user.state = :default
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Рассылкка перед каждой парой включена",
      reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
    )
  end

  def disable_pair_sending(message, user)
    user.pair_sending = false
    user.state = :default
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Рассылкка перед каждой парой выключена",
      reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
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
        text: "Тест `#{debug_command_name}` не найден.\n\nДоступные тесты: #{DebugCommands.methods.join(', ')}",
        reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
      )
      return
    end

    DebugCommands.send(debug_command_name, bot: self, user: user, message: message)
  end

  def cancel_action (message, user)
    case user.state
    when :default
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Нечего отменять",
        reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
      )
    else
      user.state = :default
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Действие отменено",
        reply_markup: user.id.to_i > 0 ? DEFAULT_REPLY_MARKUP : {remove_keyboard: true}.to_json
      )
    end
  end
end