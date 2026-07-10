#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include "ESP_I2S.h"
#include "esp_camera.h"
#include "board_config.h"

#if __has_include("secrets.h")
#include "secrets.h"
#else
#error "Создайте secrets.h из secrets.h.example и укажите WiFi + IP Mac"
#endif

#ifndef HOST_AUDIO_PORT
#define HOST_AUDIO_PORT 9999
#endif

#ifndef SAMPLE_RATE
#define SAMPLE_RATE 16000
#endif

#define AUDIO_CHUNK_SAMPLES 512
#define AUDIO_PACKET_MAGIC 0x30445541  // "AUD0"

void startCameraServer();

WiFiUDP audioUdp;
IPAddress hostIp;
I2SClass mic;
int16_t audioBuffer[AUDIO_CHUNK_SAMPLES];

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
  config.frame_size = FRAMESIZE_QVGA;
  config.pixel_format = PIXFORMAT_JPEG;
  config.grab_mode = CAMERA_GRAB_LATEST;
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.jpeg_quality = 12;
  config.fb_count = 2;

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

static void sendAudioPacket(uint32_t sequence, const int16_t *samples, size_t sampleCount) {
  uint8_t packet[8 + AUDIO_CHUNK_SAMPLES * 2];
  uint32_t magic = AUDIO_PACKET_MAGIC;
  uint16_t count = (uint16_t)sampleCount;

  memcpy(packet + 0, &magic, 4);
  memcpy(packet + 4, &sequence, 4);
  memcpy(packet + 8, &count, 2);
  memcpy(packet + 10, samples, sampleCount * sizeof(int16_t));

  audioUdp.beginPacket(hostIp, HOST_AUDIO_PORT);
  audioUdp.write(packet, 10 + sampleCount * sizeof(int16_t));
  audioUdp.endPacket();
}

void audioTask(void *parameter) {
  uint32_t sequence = 0;

  while (true) {
    size_t bytesRead = mic.readBytes((char *)audioBuffer, sizeof(audioBuffer));
    size_t sampleCount = bytesRead / sizeof(int16_t);

    if (sampleCount > 0 && WiFi.status() == WL_CONNECTED) {
      sendAudioPacket(sequence++, audioBuffer, sampleCount);
    }

    vTaskDelay(1);
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("ESP Sense Stream — camera + microphone");

  if (!initCamera()) {
    while (true) delay(1000);
  }
  Serial.println("Camera OK");

  if (!initMicrophone()) {
    Serial.println("Microphone init failed");
    while (true) delay(1000);
  }
  Serial.println("Microphone OK");

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  WiFi.setSleep(false);

  Serial.print("WiFi connecting");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();
  Serial.print("WiFi IP: ");
  Serial.println(WiFi.localIP());

  hostIp.fromString(HOST_IP);
  Serial.print("Audio UDP target: ");
  Serial.print(HOST_IP);
  Serial.print(":");
  Serial.println(HOST_AUDIO_PORT);

  startCameraServer();

  xTaskCreatePinnedToCore(audioTask, "audioTask", 8192, NULL, 1, NULL, 0);

  Serial.print("Camera stream: http://");
  Serial.print(WiFi.localIP());
  Serial.println(":81/stream");
}

void loop() {
  delay(1000);
}
