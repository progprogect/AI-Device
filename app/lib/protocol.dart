// Протокол ESP Sense v2. Спецификация: docs/ARCHITECTURE.md

class EspProtocol {
  static const String deviceName = 'ESP-Sense';

  static const String serviceUuid = 'a1b2c300-1111-2222-3333-444455556666';
  static const String dataCharUuid = 'a1b2c300-1111-2222-3333-444455556667';
  static const String cmdCharUuid = 'a1b2c300-1111-2222-3333-444455556668';
  static const String infoCharUuid = 'a1b2c300-1111-2222-3333-444455556669';

  // Пакеты данных (NOTIFY)
  static const int pktAudio = 0x01;
  static const int pktImgBegin = 0x02;
  static const int pktImgChunk = 0x03;
  static const int pktImgEnd = 0x04;
  static const int pktEvent = 0x05;
  static const int pktStatus = 0x06;

  // Команды (WRITE)
  static const int cmdStartAudio = 0x10;
  static const int cmdStopAudio = 0x11;
  static const int cmdCapturePhoto = 0x20;
  static const int cmdStartVideo = 0x30;
  static const int cmdStopVideo = 0x31;
  static const int cmdSetWifi = 0x40;

  static const int sampleRate = 16000;
}
