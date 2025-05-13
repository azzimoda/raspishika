# raspishika

Telegram-бот для удобного расписания МПК ТИУ.

# Deploy (Docker way)

`docker build -t ruby-mpk-bot .`

`docker run -it --rm \
 -e TELEGRAM_BOT_TOKEN=your_bot_token \
 ruby-mpk-bot`
