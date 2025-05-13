# raspishika

Telegram-бот для удобного расписания МПК ТИУ.

# Deploy (Docker way)

## Build the image

docker build -t ruby-mpk-bot .

## Run the container (with Telegram token)

docker run -it --rm \
 -e TELEGRAM_BOT_TOKEN=your_bot_token \
 ruby-mpk-bot
