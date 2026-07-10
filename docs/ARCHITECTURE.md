# Архитектура ESP Sense

Система из двух частей:

- **Устройство** — XIAO ESP32-S3 Sense (камера OV2640/OV3660, PDM-микрофон, BLE 5.0, Wi-Fi).
- **Мобильное приложение** — Flutter (iOS + Android): подключение, управление, приём данных, локальная расшифровка речи (whisper.cpp).

Принцип: **устройство максимально простое** (захват и передача), **вся обработка на телефоне** (порог громкости, VAD, Whisper, дальнейшая логика).

## Слои системы

```mermaid
flowchart TB
    subgraph phone [Flutter App — телефон]
        UI["UI: Connect / Start / Stop / Photo / Video"]
        BLEC[BLE Client]
        HTTPC[HTTP Client]
        PIPE["Audio Pipeline: буфер + VAD"]
        WSP["whisper.cpp FFI (large-v3-turbo)"]
        STORE["Хранилище: сессии, снимки, модель"]
    end

    subgraph esp [ESP32-S3 Sense — устройство]
        GATT["BLE GATT Server"]
        CMDH[Command Handler]
        MIC["Микрофон I2S PDM"]
        CAM[Камера]
        WEBS["Wi-Fi HTTP: MJPEG /stream"]
    end

    UI --> BLEC
    UI --> HTTPC
    BLEC <-->|"команды WRITE / данные NOTIFY"| GATT
    HTTPC <-->|"видео (MJPEG)"| WEBS
    GATT --> CMDH
    CMDH --> MIC
    CMDH --> CAM
    MIC -->|PCM| GATT
    CAM -->|JPEG| GATT
    CAM --> WEBS
    BLEC --> PIPE --> WSP --> UI
    WSP --> STORE
```

## Транспорты

| Данные | BLE | Wi-Fi |
|--------|-----|-------|
| Команды (start/stop/photo) | основной канал | — |
| Аудио PCM 16 кГц | основной канал | возможно в будущем |
| Фото JPEG (по запросу) | чанками через NOTIFY | быстрее, если сеть есть |
| Видео MJPEG | нет (не хватает полосы) | единственный вариант |
| События с кнопок устройства (будущее) | NOTIFY | — |

Wi-Fi опционален: плата и телефон в одной сети, либо телефон раздаёт hotspot и
плата подключается к нему (провижининг по BLE командой `CMD_SET_WIFI`).
У ESP нет своей SIM — «мобильная сеть» возможна только через hotspot телефона
или облачный relay (задел на будущее).

## GATT-спецификация

### Сервис

| | UUID |
|---|---|
| Service | `a1b2c300-1111-2222-3333-444455556666` |
| `data` (NOTIFY) | `a1b2c300-1111-2222-3333-444455556667` |
| `commands` (WRITE) | `a1b2c300-1111-2222-3333-444455556668` |
| `device_info` (READ) | `a1b2c300-1111-2222-3333-444455556669` |

Имя устройства в рекламе: **`ESP-Sense`**. MTU: устройство запрашивает 517.

### Команды (характеристика `commands`, WRITE)

Первый байт — опкод, дальше — полезная нагрузка (little-endian).

| Опкод | Имя | Payload | Действие |
|-------|-----|---------|----------|
| `0x10` | `CMD_START_AUDIO` | — | Начать стрим аудио (пакеты `0x01`) |
| `0x11` | `CMD_STOP_AUDIO` | — | Остановить стрим аудио |
| `0x20` | `CMD_CAPTURE_PHOTO` | — | Снять кадр, отправить пакетами `0x02..0x04` |
| `0x30` | `CMD_START_VIDEO` | — | Зарезервировано: включить MJPEG-сервер |
| `0x31` | `CMD_STOP_VIDEO` | — | Зарезервировано |
| `0x40` | `CMD_SET_WIFI` | `ssid_len u8, ssid[], pass_len u8, pass[]` | Провижининг Wi-Fi |
| `0x50` | `CMD_OTA_BEGIN` | зарезервировано | OTA-обновление прошивки (будущее) |

### Пакеты данных (характеристика `data`, NOTIFY)

Первый байт — тип пакета.

| Тип | Имя | Формат |
|-----|-----|--------|
| `0x01` | `PKT_AUDIO` | `[0x01][seq u32][count u16][pcm int16 × count]` |
| `0x02` | `PKT_IMG_BEGIN` | `[0x02][total_size u32][chunk_count u16]` |
| `0x03` | `PKT_IMG_CHUNK` | `[0x03][index u16][bytes ≤180]` |
| `0x04` | `PKT_IMG_END` | `[0x04]` |
| `0x05` | `PKT_EVENT` | `[0x05][event u8]` — кнопки на устройстве (будущее) |
| `0x06` | `PKT_STATUS` | `[0x06][audio_on u8][wifi_on u8][ip u32]` |

Аудио: PCM 16 бит, 16 кГц, моно, little-endian. ~160 сэмплов на пакет.

### `device_info` (READ)

JSON-строка:

```json
{"fw":"2.0.0","name":"ESP-Sense","audio":true,"photo":true,"video":false,"wifi_ip":""}
```

### События устройства (будущее, `PKT_EVENT`)

| Код | Имя |
|-----|-----|
| `0x01` | `EVT_BUTTON_AUDIO_START` |
| `0x02` | `EVT_BUTTON_AUDIO_STOP` |
| `0x03` | `EVT_BUTTON_PHOTO` |
| `0x04` | `EVT_BUTTON_VIDEO_TOGGLE` |

Логика приёма в приложении одинакова: неважно, пришла команда с кнопки UI
или с кнопки устройства — дальше тот же pipeline.

## Диаграммы последовательности

### Подключение

```mermaid
sequenceDiagram
    autonumber
    actor User as Пользователь
    participant App as Flutter App
    participant ESP as ESP-Sense (BLE)
    participant WiFi as ESP-Sense (Wi-Fi)

    User->>App: Открыть приложение
    App->>App: Разрешения (Bluetooth, Local Network)
    App->>ESP: Скан BLE → найден "ESP-Sense"
    User->>App: «Подключиться»
    App->>ESP: connect + MTU 517
    App->>ESP: subscribe data (NOTIFY)
    App->>ESP: read device_info
    ESP-->>App: {fw, audio, photo, video, wifi_ip}
    alt Нужно видео, Wi-Fi не настроен
        User->>App: «Настроить Wi-Fi» (SSID+пароль)
        App->>ESP: CMD_SET_WIFI
        ESP->>ESP: подключение к сети
        ESP-->>App: PKT_STATUS {wifi_on, ip}
        App->>WiFi: GET /status — проверка
    end
    App-->>User: «Подключено»
```

### Аудио и потоковая расшифровка

```mermaid
sequenceDiagram
    autonumber
    actor User as Пользователь
    participant App as Flutter App
    participant WSP as whisper.cpp
    participant ESP as ESP-Sense

    User->>App: «Start» (аудио)
    App->>ESP: CMD_START_AUDIO
    ESP->>ESP: включить микрофон
    loop Пока идёт запись
        ESP-->>App: PKT_AUDIO (PCM-чанки)
        App->>App: кольцевой буфер + VAD
        alt Накопилось окно 3-8 с или пауза в речи
            App->>WSP: transcribe(окно + контекст)
            WSP-->>App: текст сегмента
            App-->>User: частичный текст (серый) / финальный
        end
    end
    User->>App: «Stop»
    App->>ESP: CMD_STOP_AUDIO
    ESP-->>App: PKT_STATUS {audio_on: 0}
    App->>WSP: финальный прогон остатка буфера
    App->>App: сохранить сессию (WAV + текст)
```

### Фото

```mermaid
sequenceDiagram
    autonumber
    actor User as Пользователь
    participant App as Flutter App
    participant ESP as ESP-Sense

    User->>App: «Сделать фото»
    App->>ESP: CMD_CAPTURE_PHOTO
    ESP->>ESP: esp_camera_fb_get()
    ESP-->>App: PKT_IMG_BEGIN {size, chunks}
    loop По чанкам
        ESP-->>App: PKT_IMG_CHUNK {index, data}
    end
    ESP-->>App: PKT_IMG_END
    App->>App: собрать JPEG, показать, сохранить
```

### Видео (Wi-Fi)

```mermaid
sequenceDiagram
    autonumber
    actor User as Пользователь
    participant App as Flutter App
    participant ESP as ESP-Sense (BLE)
    participant WiFi as ESP-Sense (Wi-Fi)

    User->>App: «Start video»
    alt Wi-Fi доступен
        App->>ESP: CMD_START_VIDEO
        App->>WiFi: GET /stream (MJPEG)
        loop Пока видео активно
            WiFi-->>App: JPEG-кадры
            App-->>User: preview
        end
        User->>App: «Stop video»
        App->>WiFi: закрыть соединение
        App->>ESP: CMD_STOP_VIDEO
    else Только BLE
        App-->>User: «Видео недоступно без Wi-Fi»
    end
```

### Кнопки на устройстве (будущее)

```mermaid
sequenceDiagram
    autonumber
    participant ESP as ESP-Sense
    participant App as Flutter App

    ESP->>ESP: нажата кнопка на плате
    ESP-->>App: PKT_EVENT {EVT_BUTTON_PHOTO}
    App->>ESP: CMD_CAPTURE_PHOTO
    Note over ESP,App: далее — стандартный поток фото
```

## Потоковая расшифровка (Whisper)

Whisper не является стриминговой моделью, поэтому применяется псевдо-стриминг:

```mermaid
flowchart LR
    PCM["PCM с ESP (16 кГц)"] --> RING["Кольцевой буфер (30 с)"]
    RING --> VAD["VAD: энергия + паузы"]
    VAD -->|"окно 3-8 с каждые ~2 с"| W["whisper.cpp large-v3-turbo Q5"]
    W -->|"частичный текст"| UI1["UI: серый текст"]
    VAD -->|"пауза в речи"| FIN["финальный прогон сегмента"]
    FIN --> W
    W -->|"финальный текст"| UI2["UI: закреплённая строка"]
    UI2 --> LOG["Журнал сессии"]
```

- Модель: `ggml-large-v3-turbo-q5_0.bin` (~574 МБ), фолбэк `ggml-small` (~488 МБ q5 ~190 МБ).
- Контекст: последние N токенов предыдущего сегмента передаются в prompt — связный текст.
- Задержка: ~1–3 с от речи до финального текста на iPhone 14/15.
- Модель хранится вне бандла приложения и переживает обновления (см. INSTALL.md).

## Обновляемость

1. **Модель Whisper** — скачивается один раз в постоянное хранилище приложения,
   проверяется по SHA-256 из `models.json`. Обновление приложения не трогает модель.
2. **Dart-код** — Shorebird code push: патчи логики без переустановки.
3. **Прошивка ESP** — сейчас по USB (`arduino-cli upload`), в протоколе
   зарезервирован `CMD_OTA_BEGIN` для будущего OTA по BLE/Wi-Fi.
