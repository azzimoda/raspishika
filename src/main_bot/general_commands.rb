module Raspishika
  class Bot
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

    private

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

  end
end