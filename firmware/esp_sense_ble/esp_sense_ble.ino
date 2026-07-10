#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "ESP_I2S.h"
#include "esp_camera.h"
#include "board_config.h"

#define DEVICE_NAME "ESP-Sense"
#define SERVICE_UUID "a1b2c300-1111-2222-3333-444455556666"
#define DATA_CHAR_UUID "a1b2c300-1111-2222-3333-444455556667"

#define PACKET_AUDIO 0x01
#define PACKET_IMG_BEGIN 0x02
#define PACKET_IMG_CHUNK 0x03
#define PACKET_IMG_END 0x04

#define SAMPLE_RATE 16000
#define MIC_READ_SAMPLES 160
#define BLE_CHUNK_DATA 180
#define IMAGE_INTERVAL_MS 60000

BLEServer *bleServer = nullptr;
BLECharacteristic *dataChar = nullptr;
I2SClass mic;

volatile bool bleConnected = false;
volatile bool sendingImage = false;
volatile bool hasCamera = false;
volatile bool firstImagePending = false;
uint32_t audioSequence = 0;
uint32_t lastImageMs = 0;

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

static void notifyPacket(const uint8_t *data, size_t len) {
  if (!bleConnected || dataChar == nullptr || sendingImage) {
    return;
  }

  dataChar->setValue((uint8_t *)data, len);
  dataChar->notify();
}

static void sendAudioPacket(const int16_t *samples, size_t sampleCount) {
  uint8_t packet[7 + MIC_READ_SAMPLES * 2];
  uint16_t count = (uint16_t)sampleCount;

  packet[0] = PACKET_AUDIO;
  memcpy(packet + 1, &audioSequence, 4);
  memcpy(packet + 5, &count, 2);
  memcpy(packet + 7, samples, sampleCount * sizeof(int16_t));

  notifyPacket(packet, 7 + sampleCount * sizeof(int16_t));
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
  beginPacket[0] = PACKET_IMG_BEGIN;
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
    chunkPacket[0] = PACKET_IMG_CHUNK;
    memcpy(chunkPacket + 1, &index, 2);
    memcpy(chunkPacket + 3, fb->buf + offset, length);

    dataChar->setValue(chunkPacket, 3 + length);
    dataChar->notify();
    delay(35);
  }

  uint8_t endPacket = PACKET_IMG_END;
  dataChar->setValue(&endPacket, 1);
  dataChar->notify();

  sendingImage = false;
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) {
    bleConnected = true;
    firstImagePending = true;
    lastImageMs = millis();
    Serial.println("BLE client connected");
    BLEDevice::startAdvertising();
  }

  void onDisconnect(BLEServer *server) {
    bleConnected = false;
    Serial.println("BLE client disconnected");
    server->startAdvertising();
  }
};

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("ESP Sense BLE — microphone + snapshot/min");

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
  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->setName(DEVICE_NAME);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("BLE advertising as ESP-Sense");
  lastImageMs = millis();
}

void loop() {
  int16_t buffer[MIC_READ_SAMPLES];
  size_t bytesRead = mic.readBytes((char *)buffer, sizeof(buffer));
  size_t sampleCount = bytesRead / sizeof(int16_t);

  if (sampleCount > 0 && bleConnected) {
    sendAudioPacket(buffer, sampleCount);
    delay(8);
  } else {
    delay(2);
  }

  uint32_t now = millis();
  if (bleConnected && hasCamera && !sendingImage) {
    bool dueFirst = firstImagePending && (now - lastImageMs >= 5000);
    bool duePeriodic = !firstImagePending && (now - lastImageMs >= IMAGE_INTERVAL_MS);
    if (dueFirst || duePeriodic) {
      camera_fb_t *fb = esp_camera_fb_get();
      if (fb) {
        Serial.printf("Sending JPEG snapshot (%u bytes)\n", fb->len);
        sendImage(fb);
        esp_camera_fb_return(fb);
        lastImageMs = now;
        firstImagePending = false;
      }
    }
  }
}
