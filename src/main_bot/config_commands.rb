# frozen_string_literal: true

module Raspishika
  class Bot
    private

    def configure_group(_message, chat, session, quick: false)
      departments = parser.fetch_departments
      unless departments&.any?
        bot.api.send_message(
          chat_id: chat.tg_id,
          text: 'Не удалось загрузить отделения',
          reply_markup: default_reply_markup(chat.tg_id)
        )
        return
      end

      session.departments = departments.keys
      session.state = quick ? Session::State::SELECTING_DEPARTMENT_QUICK : Session::State::SELECTING_DEPARTMENT
      session.save

      bot.api.send_message(
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
      departments = parser.fetch_departments
      groups = parser.fetch_all_groups departments
      groups = groups[message.text]
      unless groups&.any?
        bot.api.send_message(
          chat_id: chat.tg_id,
          text: 'Не удалось загрузить группы для этого отделения',
          reply_markup: default_reply_markup(chat.tg_id)
        )
        session.state = Session::State::DEFAULT
        session.save
        return
      end

      session.department_name_temp = message.text
      session.groups = groups
      session.state = session.selecting_quick? ? Session::State::SELECTING_GROUP_QUICK : Session::State::SELECTING_GROUP
      session.save

      bot.api.send_message(
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
        send_week_schedule(
          message,
          chat,
          session,
          quick: group_info.merge(department: session.department_name_temp, group: message.text)
        )
      else
        chat.update department: session.department_name_temp, group: message.text

        bot.api.send_message(
          chat_id: chat.tg_id,
          text: "Теперь #{chat.private? ? 'ты' : 'вы'} в группе #{message.text}",
          reply_markup: default_reply_markup(chat.id)
        )
      end
      session.state = Session::State::DEFAULT
      session.save
    end

    def send_settings_menu(message, chat, session)
      unless chat.department && chat.group
        bot.api.send_message(chat_id: chat.tg_id, text: 'Группа не выбрана')
        return configure_group message, chat, session
      end

      session.state = Session::State::SETTINGS
      session.save

      pair_sending_label = chat.pair_sending ? LABELS[:pair_sending_off] : LABELS[:pair_sending_on]
      bot.api.send_message(
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
      session.state = Session::State::SETTING_DAILY_SENDING
      session.save

      current_configuration = chat.daily_sending_time ? " (сейчас: `#{chat.daily_sending_time}`)" : ''
      bot.api.send_message(
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
      session.state = Session::State::DEFAULT
      session.save

      bot.api.send_message(
        chat_id: chat.tg_id,
        text: "Ежедневная рассылка настроена на `#{time}`",
        parse_mode: 'Markdown',
        reply_markup: default_reply_markup(chat.id)
      )
    end

    def disable_daily_sending(_message, chat, session)
      chat.update daily_sending_time: nil
      session.state = Session::State::DEFAULT
      session.save

      bot.api.send_message(
        chat_id: chat.tg_id,
        text: 'Ежедневная рассылка отключена',
        reply_markup: default_reply_markup(chat.tg_id)
      )
    end

    def enable_pair_sending(_message, chat, session)
      chat.update pair_sending: true
      session.state = Session::State::DEFAULT
      session.save

      bot.api.send_message(
        chat_id: chat.tg_id,
        text: 'Рассылка перед парами включена',
        reply_markup: default_reply_markup(chat.tg_id)
      )
    end

    def disable_pair_sending(_message, chat, session)
      chat.update pair_sending: false
      session.state = Session::State::DEFAULT
      session.save

      bot.api.send_message(
        chat_id: chat.tg_id,
        text: 'Рассылка перед парами выключена',
        reply_markup: default_reply_markup(chat.tg_id)
      )
    end

    def cancel_action(_message, chat, session)
      reply_markup = default_reply_markup chat.tg_id
      case session.state
      when Session::State::DEFAULT
        bot.api.send_message(chat_id: chat.tg_id, text: 'Нечего отменять', reply_markup: reply_markup)
      else
        bot.api.send_message(chat_id: chat.tg_id, text: 'Действие отменено', reply_markup: reply_markup)
        session.state = Session::State::DEFAULT
        session.save
      end
    end
  end
end
