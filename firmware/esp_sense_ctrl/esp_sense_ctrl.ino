// ESP Sense v2 — командная модель управления по BLE.
// Спецификация протокола: docs/ARCHITECTURE.md

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Preferences.h>
#include "ESP_I2S.h"
#include "esp_camera.h"
#include "board_config.h"

#define FW_VERSION "2.0.0"
#define DEVICE_NAME "ESP-Sense"

#define SERVICE_UUID "a1b2c300-1111-2222-3333-444455556666"
#define DATA_CHAR_UUID "a1b2c300-1111-2222-3333-444455556667"
#define CMD_CHAR_UUID "a1b2c300-1111-2222-3333-444455556668"
#define INFO_CHAR_UUID "a1b2c300-1111-2222-3333-444455556669"

// Пакеты данных (NOTIFY)
#define PKT_AUDIO 0x01
#define PKT_IMG_BEGIN 0x02
#define PKT_IMG_CHUNK 0x03
#define PKT_IMG_END 0x04
#define PKT_EVENT 0x05
#define PKT_STATUS 0x06

// Команды (WRITE)
#define CMD_START_AUDIO 0x10
#define CMD_STOP_AUDIO 0x11
#define CMD_CAPTURE_PHOTO 0x20
#define CMD_START_VIDEO 0x30
#define CMD_STOP_VIDEO 0x31
#define CMD_SET_WIFI 0x40

#define SAMPLE_RATE 16000
#define MIC_READ_SAMPLES 160
#define BLE_CHUNK_DATA 180

BLEServer *bleServer = nullptr;
BLECharacteristic *dataChar = nullptr;
BLECharacteristic *cmdChar = nullptr;
BLECharacteristic *infoChar = nullptr;
I2SClass mic;
Preferences prefs;

volatile bool bleConnected = false;
volatile bool audioStreaming = false;
volatile bool photoRequested = false;
volatile bool sendingImage = false;
volatile bool statusPending = false;
volatile bool hasCamera = false;
uint32_t audioSequence = 0;

static bool initCamera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.grab_mode = CAMERA_GRAB_LATEST;
  config.jpeg_quality = 20;
  config.fb_count = 1;

  if (psramFound()) {
    config.frame_size = FRAMESIZE_QQVGA;
    config.fb_location = CAMERA_FB_IN_PSRAM;
    Serial.printf("PSRAM found: %u bytes\n", ESP.getPsramSize());
  } else {
    config.frame_size = FRAMESIZE_240X240;
    config.fb_location = CAMERA_FB_IN_DRAM;
    Serial.println("PSRAM not found, using DRAM");
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init failed: 0x%x\n", err);
    return false;
  }

  sensor_t *sensor = esp_camera_sensor_get();
  if (sensor && sensor->id.PID == OV3660_PID) {
    sensor->set_vflip(sensor, 1);
    sensor->set_brightness(sensor, 1);
    sensor->set_saturation(sensor, -2);
  }

  return true;
}

static bool initMicrophone() {
  mic.setPinsPdmRx(42, 41);
  return mic.begin(I2S_MODE_PDM_RX, SAMPLE_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO);
}

static void sendStatus() {
  if (!bleConnected || dataChar == nullptr) {
    return;
  }
  uint8_t packet[7];
  packet[0] = PKT_STATUS;
  packet[1] = audioStreaming ? 1 : 0;
  packet[2] = 0;  // wifi_on: видео по Wi-Fi зарезервировано
  memset(packet + 3, 0, 4);  // ip
  dataChar->setValue(packet, sizeof(packet));
  dataChar->notify();
}

static void sendAudioPacket(const int16_t *samples, size_t sampleCount) {
  if (!bleConnected || dataChar == nullptr || sendingImage) {
    return;
  }

  uint8_t packet[7 + MIC_READ_SAMPLES * 2];
  uint16_t count = (uint16_t)sampleCount;

  packet[0] = PKT_AUDIO;
  memcpy(packet + 1, &audioSequence, 4);
  memcpy(packet + 5, &count, 2);
  memcpy(packet + 7, samples, sampleCount * sizeof(int16_t));

  dataChar->setValue(packet, 7 + sampleCount * sizeof(int16_t));
  dataChar->notify();
  audioSequence++;
}

static void sendImage(camera_fb_t *fb) {
  if (!fb || !bleConnected || fb->format != PIXFORMAT_JPEG) {
    return;
  }

  sendingImage = true;

  uint16_t chunkSize = BLE_CHUNK_DATA;
  uint16_t chunkCount = (uint16_t)((fb->len + chunkSize - 1) / chunkSize);
  uint32_t totalSize = fb->len;

  uint8_t beginPacket[7];
  beginPacket[0] = PKT_IMG_BEGIN;
  memcpy(beginPacket + 1, &totalSize, 4);
  memcpy(beginPacket + 5, &chunkCount, 2);
  dataChar->setValue(beginPacket, sizeof(beginPacket));
  dataChar->notify();
  delay(40);

  for (uint16_t index = 0; index < chunkCount; index++) {
    size_t offset = (size_t)index * chunkSize;
    size_t length = chunkSize;
    if (offset + length > fb->len) {
      length = fb->len - offset;
    }

    uint8_t chunkPacket[3 + BLE_CHUNK_DATA];
    chunkPacket[0] = PKT_IMG_CHUNK;
    memcpy(chunkPacket + 1, &index, 2);
    memcpy(chunkPacket + 3, fb->buf + offset, length);

    dataChar->setValue(chunkPacket, 3 + length);
    dataChar->notify();
    delay(35);
  }

  uint8_t endPacket = PKT_IMG_END;
  dataChar->setValue(&endPacket, 1);
  dataChar->notify();

  sendingImage = false;
}

static void handleSetWifi(const uint8_t *payload, size_t len) {
  // [ssid_len u8][ssid][pass_len u8][pass] — сохраняем для будущего видео по Wi-Fi
  if (len < 2) return;
  uint8_t ssidLen = payload[0];
  if (len < (size_t)(1 + ssidLen + 1)) return;
  uint8_t passLen = payload[1 + ssidLen];
  if (len < (size_t)(2 + ssidLen + passLen)) return;

  String ssid = String((const char *)(payload + 1), ssidLen);
  String pass = String((const char *)(payload + 2 + ssidLen), passLen);

  prefs.begin("wifi", false);
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.end();
  Serial.printf("Wi-Fi credentials saved: %s\n", ssid.c_str());
}

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) {
    String value = characteristic->getValue();
    if (value.length() == 0) {
      return;
    }
    const uint8_t *data = (const uint8_t *)value.c_str();
    uint8_t opcode = data[0];

    switch (opcode) {
      case CMD_START_AUDIO:
        audioSequence = 0;
        audioStreaming = true;
        statusPending = true;
        Serial.println("CMD: start audio");
        break;
      case CMD_STOP_AUDIO:
        audioStreaming = false;
        statusPending = true;
        Serial.println("CMD: stop audio");
        break;
      case CMD_CAPTURE_PHOTO:
        photoRequested = true;
        Serial.println("CMD: capture photo");
        break;
      case CMD_START_VIDEO:
      case CMD_STOP_VIDEO:
        Serial.println("CMD: video (reserved, not implemented)");
        statusPending = true;
        break;
      case CMD_SET_WIFI:
        handleSetWifi(data + 1, value.length() - 1);
        statusPending = true;
        break;
      default:
        Serial.printf("CMD: unknown opcode 0x%02x\n", opcode);
        break;
    }
  }
};

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) {
    bleConnected = true;
    statusPending = true;
    Serial.println("BLE client connected");
  }

  void onDisconnect(BLEServer *server) {
    bleConnected = false;
    audioStreaming = false;
    photoRequested = false;
    Serial.println("BLE client disconnected");
    server->startAdvertising();
  }
};

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.printf("ESP Sense v%s — command-driven BLE\n", FW_VERSION);

  if (!initCamera()) {
    Serial.println("Camera unavailable — microphone-only mode");
  } else {
    hasCamera = true;
    Serial.println("Camera OK");
  }

  if (!initMicrophone()) {
    Serial.println("Microphone init failed");
    while (true) delay(1000);
  }
  Serial.println("Microphone OK");

  BLEDevice::init(DEVICE_NAME);
  BLEDevice::setMTU(517);

  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService *service = bleServer->createService(SERVICE_UUID);

  dataChar = service->createCharacteristic(
    DATA_CHAR_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  dataChar->addDescriptor(new BLE2902());

  cmdChar = service->createCharacteristic(
    CMD_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  cmdChar->setCallbacks(new CommandCallbacks());

  infoChar = service->createCharacteristic(
    INFO_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ
  );
  char info[160];
  snprintf(info, sizeof(info),
           "{\"fw\":\"%s\",\"name\":\"%s\",\"audio\":true,\"photo\":%s,\"video\":false}",
           FW_VERSION, DEVICE_NAME, hasCamera ? "true" : "false");
  infoChar->setValue(info);

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->setName(DEVICE_NAME);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("BLE advertising as ESP-Sense");
}

void loop() {
  if (statusPending) {
    statusPending = false;
    sendStatus();
  }

  if (photoRequested && bleConnected && hasCamera && !sendingImage) {
    photoRequested = false;
    camera_fb_t *fb = esp_camera_fb_get();
    if (fb) {
      Serial.printf("Sending JPEG snapshot (%u bytes)\n", fb->len);
      sendImage(fb);
      esp_camera_fb_return(fb);
    } else {
      Serial.println("Camera frame grab failed");
    }
  }

  if (audioStreaming && bleConnected) {
    int16_t buffer[MIC_READ_SAMPLES];
    size_t bytesRead = mic.readBytes((char *)buffer, sizeof(buffer));
    size_t sampleCount = bytesRead / sizeof(int16_t);
    if (sampleCount > 0) {
      sendAudioPacket(buffer, sampleCount);
    }
    delay(8);
  } else {
    delay(20);
  }
}
