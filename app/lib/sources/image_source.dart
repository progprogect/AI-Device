import 'dart:typed_data';

import '../services/esp_ble_service.dart';

/// Источник изображений: снимок по кнопке.
abstract class ImageSource {
  String get label;

  /// null если пользователь отменил или ошибка.
  Future<Uint8List?> capturePhoto();
}

class EspImageSource implements ImageSource {
  EspImageSource(this.ble);

  final EspBleService ble;

  @override
  String get label => 'Камера ESP-Sense';

  @override
  Future<Uint8List?> capturePhoto() async {
    await ble.capturePhoto();
    try {
      return await ble.imageStream.first.timeout(const Duration(seconds: 90));
    } catch (_) {
      return null;
    }
  }
}

/// Локальная камера: захват делегируется UI (camera_macos).
/// [captureCallback] устанавливается из ControlScreen.
class LocalImageSource implements ImageSource {
  LocalImageSource();

  Future<Uint8List?> Function()? captureCallback;

  @override
  String get label => 'Камера этого устройства';

  @override
  Future<Uint8List?> capturePhoto() async {
    if (captureCallback == null) {
      throw Exception('Камера не инициализирована');
    }
    return captureCallback!();
  }
}
