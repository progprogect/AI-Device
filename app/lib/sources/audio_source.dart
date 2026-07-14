import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../protocol.dart';
import '../services/app_log.dart';
import '../services/esp_ble_service.dart';
import '../services/wav_writer.dart';

/// Источник аудио: запись по кнопке → WAV-файл.
abstract class AudioSource {
  String get label;

  /// Последний успешно сохранённый WAV (после stopRecording).
  String? get lastRecordedPath;

  Future<void> startRecording();
  Future<String?> stopRecording(); // путь к WAV или null
  void dispose();
}

/// Локальный микрофон (Mac/iPhone).
class LocalAudioSource implements AudioSource {
  LocalAudioSource() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;
  String? _path;
  String? _lastRecordedPath;
  final _log = AppLog.instance;

  @override
  String? get lastRecordedPath => _lastRecordedPath;

  @override
  String get label => 'Микрофон этого устройства';

  @override
  Future<void> startRecording() async {
    if (!await _recorder.hasPermission()) {
      throw Exception('Нет доступа к микрофону');
    }
    final dir = await getTemporaryDirectory();
    _path = '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: EspProtocol.sampleRate,
        numChannels: 1,
      ),
      path: _path!,
    );
    _log.info('LocalAudio: recording to $_path');
  }

  @override
  Future<String?> stopRecording() async {
    final path = await _recorder.stop();
    final resolved = path ?? _path;
    _log.info('LocalAudio: stopped $resolved');
    if (resolved != null) {
      _lastRecordedPath = resolved;
    }
    return resolved;
  }

  @override
  void dispose() {
    _recorder.dispose();
  }
}

/// ESP BLE: PCM-чанки → WAV при остановке.
class EspAudioSource implements AudioSource {
  EspAudioSource(this.ble);

  final EspBleService ble;
  final List<int> _buffer = [];
  StreamSubscription<Int16List>? _sub;
  String? _lastRecordedPath;
  final _log = AppLog.instance;

  @override
  String? get lastRecordedPath => _lastRecordedPath;

  @override
  String get label => 'ESP-Sense (Bluetooth)';

  @override
  Future<void> startRecording() async {
    _buffer.clear();
    await ble.startAudio();
    _sub = ble.audioStream.listen((samples) {
      _buffer.addAll(samples);
    });
    _log.info('EspAudio: started');
  }

  @override
  Future<String?> stopRecording() async {
    await _sub?.cancel();
    _sub = null;
    await ble.stopAudio();

    if (_buffer.isEmpty) return null;

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/esp_${DateTime.now().millisecondsSinceEpoch}.wav';
    final wav = pcmToWav(Int16List.fromList(_buffer));
    await File(path).writeAsBytes(wav);
    _buffer.clear();
    _lastRecordedPath = path;
    _log.info('EspAudio: saved $path (${wav.length} bytes)');
    return path;
  }

  @override
  void dispose() {
    _sub?.cancel();
  }
}
