# frozen_string_literal: true

module Raspishika
  class Bot
    private

    def configure_group(_message, chat, session, quick: false)
      departments = parser.fetch_departments
      unless departments&.any?
        send_message(chat_id: chat.tg_id, text: 'Не удалось загрузить отделения', reply_markup: :default)
        return
      end

      session.departments = departments.keys
      quick ? session.selecting_department_quick! : session.selecting_department!
      session.save

      send_message(
        chat_id: chat.tg_id,
        text: 'Выбери отделение',
        reply_markup: {
          keyboard: [['Отмена']] + departments.keys.each_slice(2).to_a,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    end

    def select_department(message, chat, session)
      groups = parser.fetch_all_groups
      groups = groups[message.text]
      unless groups&.any?
        send_message(
          chat_id: chat.tg_id,
          text: 'Не удалось загрузить группы для этого отделения',
          reply_markup: :default
        )
        session.default!
        session.save
        return
      end

      session.department_name_temp = message.text
      session.groups = groups
      session.selecting_quick? ? session.selecting_group_quick! : session.selecting_group!
      session.save

      send_message(
        chat_id: chat.tg_id,
        text: 'Выбери группу',
        reply_markup: {
          keyboard: [['Отмена']] + groups.keys.each_slice(2).to_a,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    end

    def select_group(message, chat, session)
      group_info = session.groups[message.text]
      session.groups = {}

      if session.selecting_quick?
        group_info = group_info.merge department: session.department_name_temp, group: message.text
        send_week_schedule message, chat, session, quick: group_info
      else
        chat.update department: session.department_name_temp, group: message.text
        send_message(
          chat_id: chat.tg_id,
          text: "Теперь #{chat.private? ? 'ты' : 'вы'} в группе #{message.text}",
          reply_markup: :default
        )
      end
      session.default!
      session.save
    end

    def send_settings_menu(message, chat, session)
      unless chat.department && chat.group
        send_message(chat_id: chat.tg_id, text: 'Группа не выбрана')
        return configure_group message, chat, session
      end

      session.settings!
      session.save

      pair_sending_label = chat.pair_sending ? LABELS[:pair_sending_off] : LABELS[:pair_sending_on]
      send_message(
        chat_id: chat.tg_id,
        text: 'Что настроить?',
        reply_markup: {
          keyboard: [['Отмена'], [LABELS[:my_group], 'Ежедневная рассылка', pair_sending_label]],
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    end

    def configure_daily_sending(_message, chat, session)
      session.setting_daily_sending!
      session.save

      current_configuration = chat.daily_sending_time ? " (сейчас: `#{chat.daily_sending_time}`)" : ''
      send_message(
        chat_id: chat.tg_id,
        text: "Выберите время для ежедневной рассылки#{current_configuration}\nНапример: `7:00`",
        parse_mode: 'Markdown',
        reply_markup: {
          keyboard: [['Отмена'], ['Отключить']],
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    end

    def set_daily_sending(message, chat, session)
      time = Time.parse(message.text).strftime('%H:%M')
      chat.update daily_sending_time: time
      session.default!
      session.save

      send_message(
        chat_id: chat.tg_id,
        text: "Ежедневная рассылка настроена на `#{time}`",
        parse_mode: 'Markdown',
        reply_markup: :default
      )
    end

    def disable_daily_sending(_message, chat, session)
      chat.update daily_sending_time: nil
      session.default!
      session.save

      send_message(chat_id: chat.tg_id, text: 'Ежедневная рассылка отключена', reply_markup: :default)
    end

    def enable_pair_sending(_message, chat, session)
      chat.update pair_sending: true
      session.default!
      session.save

      send_message(chat_id: chat.tg_id, text: 'Рассылка перед парами включена', reply_markup: :default)
    end

    def disable_pair_sending(_message, chat, session)
      chat.update pair_sending: false
      session.default!
      session.save

      send_message(chat_id: chat.tg_id, text: 'Рассылка перед парами выключена', reply_markup: :default)
    end

    def set_access_level(chat, session, level)
      unless level.is_a?(Integer) && [0, 1, 2].include?(level)
        raise ArgumentError, "Invalid level argument: #{level.inspect} (#{level.class})"
      end

      chat.update access_level: level
      session.default!
      session.save

      send_message chat_id: chat.tg_id, text: "Текущий уровень доступа: #{level}", reply_markup: :default
    end

    def cancel_action(_message, chat, session)
      if session.default?
        send_message(chat_id: chat.tg_id, text: 'Нечего отменять', reply_markup: :default)
      else
        send_message(chat_id: chat.tg_id, text: 'Действие отменено', reply_markup: :default)
        session.default!
        session.save
      end
    end
  end
end
