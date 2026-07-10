import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../protocol.dart';

enum EspConnectionState { disconnected, scanning, connecting, connected }

class EspDeviceInfo {
  final String firmware;
  final bool audio;
  final bool photo;
  final bool video;

  const EspDeviceInfo({
    this.firmware = '?',
    this.audio = false,
    this.photo = false,
    this.video = false,
  });

  factory EspDeviceInfo.fromJson(Map<String, dynamic> json) => EspDeviceInfo(
        firmware: json['fw']?.toString() ?? '?',
        audio: json['audio'] == true,
        photo: json['photo'] == true,
        video: json['video'] == true,
      );
}

/// BLE-клиент устройства ESP-Sense: подключение, команды, разбор пакетов.
class EspBleService {
  final _stateController =
      StreamController<EspConnectionState>.broadcast();
  final _audioController = StreamController<Int16List>.broadcast();
  final _imageController = StreamController<Uint8List>.broadcast();
  final _statusController = StreamController<bool>.broadcast();

  Stream<EspConnectionState> get connectionState => _stateController.stream;

  /// PCM 16 бит 16 кГц моно.
  Stream<Int16List> get audioStream => _audioController.stream;

  /// Собранные JPEG-снимки.
  Stream<Uint8List> get imageStream => _imageController.stream;

  /// audio_on из PKT_STATUS.
  Stream<bool> get deviceAudioOn => _statusController.stream;

  EspConnectionState _state = EspConnectionState.disconnected;
  EspConnectionState get state => _state;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmdChar;
  EspDeviceInfo deviceInfo = const EspDeviceInfo();

  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  // Сборка изображения
  int _imageSize = 0;
  final Map<int, Uint8List> _imageChunks = {};

  void _setState(EspConnectionState next) {
    _state = next;
    _stateController.add(next);
  }

  Future<void> connect() async {
    if (_state == EspConnectionState.connecting ||
        _state == EspConnectionState.connected) {
      return;
    }
    _setState(EspConnectionState.scanning);

    try {
      final device = await _scanForDevice();
      if (device == null) {
        _setState(EspConnectionState.disconnected);
        throw Exception('Устройство $espName не найдено. Проверьте питание.');
      }

      _setState(EspConnectionState.connecting);
      _device = device;

      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected &&
            _state == EspConnectionState.connected) {
          _cleanup();
          _setState(EspConnectionState.disconnected);
        }
      });

      await device.connect(
        license: License.nonprofit, // личное использование
        mtu: 517,
        timeout: const Duration(seconds: 15),
      );

      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid.str128.toLowerCase() == EspProtocol.serviceUuid,
        orElse: () => throw Exception('Сервис ESP-Sense не найден на устройстве'),
      );

      BluetoothCharacteristic? dataChar;
      BluetoothCharacteristic? infoChar;
      for (final c in service.characteristics) {
        final uuid = c.uuid.str128.toLowerCase();
        if (uuid == EspProtocol.dataCharUuid) dataChar = c;
        if (uuid == EspProtocol.cmdCharUuid) _cmdChar = c;
        if (uuid == EspProtocol.infoCharUuid) infoChar = c;
      }
      if (dataChar == null || _cmdChar == null) {
        throw Exception('Характеристики протокола не найдены');
      }

      if (infoChar != null) {
        try {
          final raw = await infoChar.read();
          deviceInfo =
              EspDeviceInfo.fromJson(jsonDecode(utf8.decode(raw)));
        } catch (_) {
          deviceInfo = const EspDeviceInfo();
        }
      }

      _notifySub = dataChar.onValueReceived.listen(_onPacket);
      await dataChar.setNotifyValue(true);

      _setState(EspConnectionState.connected);
    } catch (e) {
      _cleanup();
      await _device?.disconnect();
      _setState(EspConnectionState.disconnected);
      rethrow;
    }
  }

  static String get espName => EspProtocol.deviceName;

  Future<BluetoothDevice?> _scanForDevice() async {
    BluetoothDevice? found;
    final completer = Completer<BluetoothDevice?>();

    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (r.advertisementData.advName == EspProtocol.deviceName ||
            r.device.platformName == EspProtocol.deviceName) {
          found = r.device;
          if (!completer.isCompleted) completer.complete(found);
        }
      }
    });

    await FlutterBluePlus.startScan(
      withServices: [Guid(EspProtocol.serviceUuid)],
      timeout: const Duration(seconds: 15),
    );

    final timer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) completer.complete(null);
    });

    final device = await completer.future;
    timer.cancel();
    await sub.cancel();
    await FlutterBluePlus.stopScan();
    return device;
  }

  Future<void> disconnect() async {
    _cleanup();
    await _device?.disconnect();
    _device = null;
    _setState(EspConnectionState.disconnected);
  }

  void _cleanup() {
    _notifySub?.cancel();
    _notifySub = null;
    _connSub?.cancel();
    _connSub = null;
    _cmdChar = null;
    _imageChunks.clear();
  }

  Future<void> _sendCommand(List<int> bytes) async {
    final c = _cmdChar;
    if (c == null) throw Exception('Не подключено');
    await c.write(bytes, withoutResponse: true);
  }

  Future<void> startAudio() => _sendCommand([EspProtocol.cmdStartAudio]);
  Future<void> stopAudio() => _sendCommand([EspProtocol.cmdStopAudio]);
  Future<void> capturePhoto() => _sendCommand([EspProtocol.cmdCapturePhoto]);

  Future<void> setWifi(String ssid, String password) async {
    final s = utf8.encode(ssid);
    final p = utf8.encode(password);
    await _sendCommand([
      EspProtocol.cmdSetWifi,
      s.length,
      ...s,
      p.length,
      ...p,
    ]);
  }

  void _onPacket(List<int> raw) {
    if (raw.isEmpty) return;
    final data = Uint8List.fromList(raw);
    final bd = ByteData.sublistView(data);

    switch (data[0]) {
      case EspProtocol.pktAudio:
        if (data.length < 7) return;
        final count = bd.getUint16(5, Endian.little);
        final available = (data.length - 7) ~/ 2;
        final n = count < available ? count : available;
        final samples = Int16List(n);
        for (var i = 0; i < n; i++) {
          samples[i] = bd.getInt16(7 + i * 2, Endian.little);
        }
        _audioController.add(samples);
        break;

      case EspProtocol.pktImgBegin:
        if (data.length < 7) return;
        _imageSize = bd.getUint32(1, Endian.little);
        _imageChunks.clear();
        break;

      case EspProtocol.pktImgChunk:
        if (data.length < 3) return;
        final index = bd.getUint16(1, Endian.little);
        _imageChunks[index] = data.sublist(3);
        break;

      case EspProtocol.pktImgEnd:
        _assembleImage();
        break;

      case EspProtocol.pktStatus:
        if (data.length < 2) return;
        _statusController.add(data[1] == 1);
        break;
    }
  }

  void _assembleImage() {
    if (_imageChunks.isEmpty || _imageSize == 0) return;
    final keys = _imageChunks.keys.toList()..sort();
    final builder = BytesBuilder(copy: false);
    for (final k in keys) {
      builder.add(_imageChunks[k]!);
    }
    var bytes = builder.takeBytes();
    if (bytes.length > _imageSize) {
      bytes = bytes.sublist(0, _imageSize);
    }
    // Допускаем небольшие потери чанков, JPEG обычно декодируется
    if (bytes.length >= _imageSize * 0.9) {
      _imageController.add(bytes);
    }
    _imageChunks.clear();
    _imageSize = 0;
  }

  void dispose() {
    _cleanup();
    _stateController.close();
    _audioController.close();
    _imageController.close();
    _statusController.close();
  }
}
