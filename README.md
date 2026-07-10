# ESP Sense / AI Device

Система из ESP32-S3 Sense (камера + микрофон) и мобильного приложения Flutter.

- **Устройство** передаёт аудио и фото по BLE по команде.
- **Приложение** (iOS / Android) подключается, управляет записью, расшифровывает речь локально через Whisper.

## Структура

| Папка | Описание |
|-------|----------|
| `firmware/esp_sense_ctrl/` | Прошивка v2 (командный BLE-протокол) |
| `app/` | Flutter-приложение |
| `server/` | Python-сервер для отладки на Mac |
| `docs/` | Архитектура, план, инструкции по установке |

## Документация

- [Архитектура и протокол BLE](docs/ARCHITECTURE.md)
- [План разработки](docs/PLAN.md)
- [Установка на iPhone (Sideloadly)](docs/INSTALL.md)

## iOS без Xcode на Mac

IPA собирается в GitHub Actions:

1. Push в `main` → вкладка **Actions** → workflow **Build iOS IPA**
2. Скачать артефакт `esp-sense-ipa`
3. Установить через [Sideloadly](https://sideloadly.io) (см. `docs/INSTALL.md`)

## Прошивка ESP

```bash
cd firmware/esp_sense_ctrl
arduino-cli compile --fqbn esp32:esp32:XIAO_ESP32S3:PSRAM=opi
arduino-cli upload -p /dev/cu.usbmodem101 --fqbn esp32:esp32:XIAO_ESP32S3:PSRAM=opi
```

## Проверка прошивки (Mac)

```bash
cd server && source .venv/bin/activate && python test_ctrl.py
```
