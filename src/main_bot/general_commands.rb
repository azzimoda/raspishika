# frozen_string_literal: true

module Raspishika
  class Bot
    START_MESSAGE = <<~MARKDOWN.escape_markdown.freeze
      Привет! Я предоставляю удобный способ получать расписание пар МПК ТИУ

      Для этого тебе нужно задать группу с помощью команды /set_group. \
      После этого ты можешь получать расписание на неделю (/week), на завтра (/tomorrow) или \
      оставшиеся пары сегодня (/left).

      Также ты можешь использовать кнопки клавиатуры и добавлять меня в группы. \
      Остальные команды перечислены в /help.

      По всем вопросам обращайтесь к расработчику @MazzzaRellla или пишите в комментарии канала @mazzaLLM.
    MARKDOWN
    HELP_MESSAGE = <<~MARKDOWN.escape_markdown.freeze
      Доступные команды:

      - /left — Оставшиеся пары
      - /tomorrow — Расписание на завтра
      - /week — Расписание на неделю
      - /quick — Расписание другой группы
      - /teacher — Расписание преподавателя
      - /daily_sending — Настроить ежедневную рассылку
      - /daily_sending_off — Выключить ежедневную рассылку
      - /pair_sending_on — Включить уведомления перед парами
      - /pair_sending_off — Выключить уведомления перед парами
      - /set_group — Изменить свою группу
      - /cancel — Отменить действие или выйти из меню
      - /stop — Удалить данные о себе и остановить рассылки
      - /help — Это сообщение

      По всем вопросам обращайтесь к расработчику @MazzzaRellla или пишите в комментарии канала @mazzaLLM.
    MARKDOWN

    private

    def start_message(_message, chat, _session)
      send_message(chat_id: chat.tg_id, text: START_MESSAGE, parse_mode: 'Markdown',
                   reply_markup: default_reply_markup(chat.tg_id))
    end

    def help_message(_message, chat, session)
      session.default!
      session.save
      send_message(chat_id: chat.tg_id, text: HELP_MESSAGE, parse_mode: 'Markdown',
                   reply_markup: default_reply_markup(chat.tg_id))
    end

    def stop(message, chat, _session)
      chat.destroy

      send_message(
        chat_id: message.chat.id,
        text: "Ваши данные были удалены, и вы больше не будете получать рассылки от этого бота.\n" \
              'Спасибо за использование!',
        reply_markup: { remove_keyboard: true }.to_json
      )

      chat_title = message.chat.type == 'private' ? message.from.full_name : message.chat.title
      report "Chat #{chat_title} @#{message.chat.username} ##{message.chat.id} stopped the bot :("
    end
  end
end
