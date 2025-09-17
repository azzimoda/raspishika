# raspishika

Telegram-бот для удобного расписания МПК ТИУ.

## Deploy (Docker way)

### Build

```bash
docker build -t raspishika-bot .
```

### Run

Edit `config/config.yml` and run:

```bash
docker run -it --rm \
  -v ./data:/app/data -v ./config:/app/config \
  raspishika-bot
```
