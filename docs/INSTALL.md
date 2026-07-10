# Установка приложения ESP Sense

## iOS — сборка через GitHub Actions (без Xcode на Mac)

Если на Mac мало места для Xcode (~12–35 ГБ), IPA собирается в облаке:

1. Код в репозитории [progprogect/AI-Device](https://github.com/progprogect/AI-Device)
2. GitHub → **Actions** → **Build iOS IPA** → дождаться зелёной галочки
3. Внизу run → **Artifacts** → скачать `esp-sense-ipa.zip`
4. Распаковать → получите `esp_sense_app.ipa`
5. Установить через Sideloadly (инструкция ниже)

Workflow запускается автоматически при push в `main` (если менялся `app/`),
или вручную: Actions → Build iOS IPA → **Run workflow**.

IPA можно переслать себе в Telegram / AirDrop — на iPhone из Telegram
файл не установится напрямую, его нужно открыть на Mac в Sideloadly.

---

## iOS — без App Store (Sideloadly + бесплатный Apple ID)

**Почему нельзя «просто скинуть файл в Telegram»:** iOS не устанавливает
неподписанные IPA. Файл можно передать как угодно (Telegram, AirDrop), но
ставится он только через подпись вашим Apple ID с Mac. Ограничения бесплатного
Apple ID: подпись живёт **7 дней** (потом переустановка поверх), максимум
**3 приложения** одновременно.

### Разовая настройка

0. Для **сборки** IPA нужен полный Xcode (из App Store, ~12 ГБ) и CocoaPods:

   ```bash
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   brew install cocoapods
   ```

1. Установите [Sideloadly](https://sideloadly.io) на Mac.
2. Подключите iPhone кабелем (первый раз — «Доверять этому компьютеру»).
3. На iPhone: Настройки → Основные → VPN и управление устройством —
   после первой установки подтвердите доверие своему Apple ID.

### Сборка и установка

```bash
cd app
flutter build ipa --no-codesign
# IPA: build/ios/archive/... или build/ios/ipa/*.ipa
```

1. Откройте Sideloadly, перетащите IPA.
2. Укажите свой Apple ID (лучше отдельный, не основной).
3. Нажмите Start — приложение появится на iPhone.

### Обновление (важно!)

- Ставьте новую версию **поверх старой, не удаляя** приложение — тогда
  скачанная модель Whisper (~574 МБ) и данные сохранятся.
- Раз в 7 дней подпись истекает — просто повторите установку через Sideloadly
  (данные не теряются).
- Патчи логики прилетают через Shorebird вообще без переустановки.

### Передача через Telegram (iOS)

Сам IPA можно переслать в Telegram (например, себе в «Избранное»), но на
телефоне он не установится — его нужно скачать на Mac и прогнать через
Sideloadly. Для «скинул файл — поставил с телефона» подходит только Android.

## Android — APK через Telegram

```bash
cd app
flutter build apk --release
# APK: build/app/outputs/flutter-apk/app-release.apk
```

1. Отправьте `app-release.apk` в Telegram (себе или получателю).
2. На телефоне: скачать файл → открыть → разрешить установку из этого
   источника → установить. Готово.

## Модель Whisper

- При первом запуске приложение предложит скачать модель
  `large-v3-turbo Q5_0` (~574 МБ) с Hugging Face. Нужен Wi-Fi.
- Модель хранится в постоянной папке приложения и **не** скачивается заново
  при обновлениях.
- В настройках можно переключиться на `small` (быстрее, менее точная).

## Прошивка ESP (по USB)

Устройство подключено к Mac по USB-C.

```bash
cd firmware/esp_sense_ctrl
arduino-cli compile --fqbn esp32:esp32:XIAO_ESP32S3:PSRAM=opi
arduino-cli upload -p /dev/cu.usbmodem101 --fqbn esp32:esp32:XIAO_ESP32S3:PSRAM=opi
```

Порт может отличаться — проверить: `arduino-cli board list`.

Проверка прошивки без телефона:

```bash
cd server && source .venv/bin/activate
python test_ctrl.py           # start/stop audio + фото
```

В будущем: OTA-обновление прошивки по BLE/Wi-Fi (`CMD_OTA_BEGIN`,
зарезервировано в протоколе) — без подключения к ПК.
