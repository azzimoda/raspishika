# raspishika

Telegram-бот для удобного расписания МПК ТИУ.

## Внимание!

Данный репозиторий более не будет поддерживаться и будет перенесён в публичный архив. Проект был переписан на другой язык программирования, подробнее: [azzimoda/raspishika-go](https://github.com/azzimoda/raspishika-go).

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
