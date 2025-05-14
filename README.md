# raspishika

Telegram-бот для удобного расписания МПК ТИУ.

## Deploy (Docker way)

```bash
docker build -t ruby-mpk-bot .
```

```bash
docker run -it --rm \
  -v ./data:/app/data \
  -e TELEGRAM_BOT_TOKEN=your_bot_token \
  ruby-mpk-bot
```
