module Raspishika
  class Bot
    START_MESSAGE = <<~MARKDOWN
    Привет!
    
    Этот бот предоставляет удобный способ получать расписание пар МПК ТИУ.

    Для этого тебе нужно задать группу с помощью команды /set_group или кнопкой "Выбрать группу". \
    После этого ты можешь получить расписание на неделю (/week), на завтра (/tomorrow) или \
    оставшиеся пары сегодня (/left).

    Также ты можешь:
    - использовать кнопки клавиатуры для быстрого доступа к основным функциям,
    - посмотреть расписание другой группы не меняя свою (//quick_schedule или кнопкой "Быстрое расписание",
    - настроить ежедневную рассылку недельного расписания (/configure_daily_sending),
    - включить/выключить рассылку перед парами за 15 минут (/pair_sending_on и /pair_sending_off),
    - использовать бота в групповых чатах,
    - удалить свои данные (/stop).

    По всем вопросам и предложениям обращайтесь к расработчику @MazzzaRellla или пишите в комментарии канала @mazzaLLM.
    MARKDOWN

    HELP_MESSAGE = <<~MARKDOWN
    Доступные команды:

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
    - /cancel — Отменить действие или выйти из меню
    - /stop — Остановить бота и удалить данные о себе
    - /help — Это сообщение

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
        chat_id: message.chat.id,
        text:
          "Ваши данные были удалены, и Вы больше не будете получать рассылки от этого бота.\n" \
          "Спасибо за использование!",
        reply_markup: {remove_keyboard: true}.to_json
      )
    end
  end
end