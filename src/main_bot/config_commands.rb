# frozen_string_literal: true

module Raspishika
  class Bot
    private

    def configure_group(_message, user, quick: false)
      departments = parser.fetch_departments

      unless departments&.any?
        bot.api.send_message(
          chat_id: user.id,
          text: 'Не удалось загрузить отделения',
          reply_markup: default_reply_markup(user.id)
        )

        return
      end

      user.departments = departments.keys
      user.state = quick ? User::State::SELECTING_DEPARTMENT_QUICK : User::State::SELECTING_DEPARTMENT

      bot.api.send_message(
        chat_id: user.id,
        text: 'Выбери отделение',
        reply_markup: {
          keyboard: [['Отмена']] + departments.keys.each_slice(2).to_a,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    rescue StandardError => e
      user.push_command_usage command: quick ? '/quick_schedule' : '/set_group', ok: false
      raise e
    end

    def select_department(message, user)
      departments = parser.fetch_departments
      groups = parser.fetch_all_groups departments
      groups = groups[message.text]
      unless groups&.any?
        bot.api.send_message(
          chat_id: message.chat.id,
          text: 'Не удалось загрузить группы для этого отделения',
          reply_markup: default_reply_markup(user.id)
        )
        user.state = User::State::DEFAULT
        return
      end

      user.department_name_temp = message.text
      user.groups = groups
      user.state = user.selecting_quick? ? User::State::SELECTING_GROUP_QUICK : User::State::SELECTING_GROUP

      bot.api.send_message(
        chat_id: message.chat.id,
        text: 'Выбери группу',
        reply_markup: {
          keyboard: [['Отмена']] + groups.keys.each_slice(2).to_a,
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    rescue StateError => e
      user.push_command_usage command: user.selecting_quick? ? '/quick_schedule' : '/set_group', ok: false
      raise e
    end

    def select_group(message, user)
      group_info = user.groups[message.text]

      user.groups = {}

      if user.selecting_quick?
        send_week_schedule(
          message,
          user,
          quick: group_info.merge(department: user.department_name_temp, group: message.text)
        )

        user.push_command_usage command: '/quick_schedule'
      else
        user.department_name = user.department_name_temp
        user.group_name = message.text

        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Теперь #{message.chat.id.positive? ? 'ты' : 'вы'} в группе #{message.text}",
          reply_markup: default_reply_markup(user.id)
        )

        user.push_command_usage command: '/set_group'
      end
      user.state = User::State::DEFAULT
    rescue StandardError => e
      user.push_command_usage command: user.selecting_quick? ? '/quick_schedule' : '/set_group', ok: false
      raise e
    end

    def send_settings_menu(message, user)
      unless user.department_name && user.group_name
        bot.api.send_message(chat_id: user.id, text: 'Группа не выбрана')
        return configure_group(message, user)
      end

      user.state = User::State::SETTINGS

      pair_sending_label = user.pair_sending ? LABELS[:pair_sending_off] : LABELS[:pair_sending_on]
      bot.api.send_message(
        chat_id: user.id,
        text: 'Что настроить?',
        reply_markup: {
          keyboard: [['Отмена'], [LABELS[:my_group], 'Ежедневная рассылка', pair_sending_label]],
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
      user.push_command_usage command: Bot::LABELS[:settings].downcase
    rescue StandardError => e
      user.push_command_usage command: Bot::LABELS[:settings].downcase, ok: false
      raise e
    end

    def configure_daily_sending(message, user)
      user.state = User::State::SETTING_DAILY_SENDING

      current_configuration = user.daily_sending ? " (сейчас: `#{user.daily_sending}`)" : ''
      bot.api.send_message(
        chat_id: message.chat.id,
        text: "Выберите время для ежедневной рассылки#{current_configuration}\nНапример: `7:00`",
        parse_mode: 'Markdown',
        reply_markup: {
          keyboard: [['Отмена'], ['Отключить']],
          resize_keyboard: true,
          one_time_keyboard: true
        }.to_json
      )
    rescue StandardError => e
      user.push_command_usage command: '/configure_daily_sending', ok: false
      raise e
    end

    def set_daily_sending(message, user)
      user.daily_sending = Time.parse(message.text).strftime('%H:%M')
      user.state = User::State::DEFAULT

      bot.api.send_message(
        chat_id: user.id,
        text: "Ежедневная рассылка настроена на `#{user.daily_sending}`",
        parse_mode: 'Markdown',
        reply_markup: default_reply_markup(user.id)
      )
      user.push_command_usage command: '/configure_daily_sending'
    rescue StandardError => e
      user.push_command_usage command: '/configure_daily_sending', ok: false
      raise e
    end

    def disable_daily_sending(message, user)
      user.daily_sending = nil
      user.state = User::State::DEFAULT

      bot.api.send_message(
        chat_id: user.id,
        text: 'Ежедневная рассылка отключена',
        reply_markup: default_reply_markup(user.id)
      )
      user.push_command_usage command: '/configure_daily_sending'
    rescue StandardError => e
      user.push_command_usage command: '/configure_daily_sending', ok: false
      raise e
    end

    def enable_pair_sending(message, user)
      user.pair_sending = true
      user.state = User::State::DEFAULT

      bot.api.send_message(
        chat_id: message.chat.id,
        text: 'Рассылка перед парами включена',
        reply_markup: default_reply_markup(user.id)
      )
      user.push_command_usage command: '/pair_sending_on'
    rescue StandardError => e
      user.push_command_usage command: '/pair_sending_on', ok: false
      raise e
    end

    def disable_pair_sending(message, user)
      user.pair_sending = false
      user.state = User::State::DEFAULT

      bot.api.send_message(
        chat_id: message.chat.id,
        text: 'Рассылка перед парами выключена',
        reply_markup: default_reply_markup(user.id)
      )
      user.push_command_usage command: '/pair_sending_off'
    rescue StandardError => e
      user.push_command_usage command: '/pair_sending_off', ok: false
      raise e
    end

    def cancel_action(_message, user)
      reply_markup = default_reply_markup user.id
      case user.state
      when User::State::DEFAULT
        bot.api.send_message(chat_id: user.id, text: 'Нечего отменять', reply_markup: reply_markup)
      else
        user.state = User::State::DEFAULT
        bot.api.send_message(chat_id: user.id, text: 'Действие отменено', reply_markup: reply_markup)
      end
    end
  end
end
