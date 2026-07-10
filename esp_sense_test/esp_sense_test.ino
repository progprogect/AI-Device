#include <Arduino.h>

void setup() {
  Serial.begin(115200);
  delay(1000);

  pinMode(LED_BUILTIN, OUTPUT);

  Serial.println();
  Serial.println("=== ESP Sense test ===");
  Serial.printf("Chip model: %s\n", ESP.getChipModel());
  Serial.printf("Chip revision: %d\n", ESP.getChipRevision());
  Serial.printf("CPU freq: %d MHz\n", ESP.getCpuFreqMHz());
  Serial.printf("Flash size: %u bytes\n", ESP.getFlashChipSize());
  Serial.printf("Free heap: %u bytes\n", ESP.getFreeHeap());
  Serial.println("Blinking LED. Open serial monitor at 115200 baud.");
}

void loop() {
  digitalWrite(LED_BUILTIN, HIGH);
  Serial.println("LED ON");
  delay(500);

  digitalWrite(LED_BUILTIN, LOW);
  Serial.println("LED OFF");
  delay(500);
}
