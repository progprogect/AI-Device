import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import '../protocol.dart';
import 'wav_writer.dart';

enum ModelState { notDownloaded, downloading, ready, transcribing }

class TranscriptSegment {
  final String text;
  final bool isFinal;
  final DateTime time;

  TranscriptSegment(this.text, {required this.isFinal}) : time = DateTime.now();
}

/// Псевдо-стриминговая расшифровка: буфер PCM → сегментация по паузам (VAD
/// по энергии) → whisper.cpp по сегментам. Схема: docs/ARCHITECTURE.md.
class TranscriptionService {
  TranscriptionService({this.model = WhisperModel.largeV3Turbo});

  WhisperModel model;
  final WhisperController _controller = WhisperController();

  final _segmentsController = StreamController<TranscriptSegment>.broadcast();
  final _modelStateController = StreamController<ModelState>.broadcast();
  final _downloadProgress = StreamController<double>.broadcast();

  Stream<TranscriptSegment> get segments => _segmentsController.stream;
  Stream<ModelState> get modelState => _modelStateController.stream;
  Stream<double> get downloadProgress => _downloadProgress.stream;

  ModelState _state = ModelState.notDownloaded;
  ModelState get state => _state;

  // Параметры сегментации
  static const int _sampleRate = EspProtocol.sampleRate;
  static const double _speechThresholdDb = -38;
  static const int _silenceMsToFinalize = 900;
  static const int _maxSegmentMs = 8000;
  static const int _minSegmentMs = 600;

  final List<int> _buffer = [];
  bool _inSpeech = false;
  int _silenceMs = 0;
  bool _running = false;
  bool _busy = false;

  void _setState(ModelState s) {
    _state = s;
    _modelStateController.add(s);
  }

  Future<bool> isModelDownloaded() async {
    final path = await _controller.getPath(model);
    final exists = File(path).existsSync();
    _setState(exists ? ModelState.ready : ModelState.notDownloaded);
    return exists;
  }

  /// Скачивает модель с Hugging Face в постоянное хранилище приложения.
  /// Модель переживает обновления приложения (см. docs/INSTALL.md).
  Future<void> downloadModel() async {
    _setState(ModelState.downloading);
    try {
      final path = await _controller.getPath(model);
      final file = File(path);
      final uri = model.modelUri;

      final request = await HttpClient().getUrl(uri);
      final response = await request.close();
      final total = response.contentLength;
      var received = 0;

      final sink = file.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _downloadProgress.add(received / total);
        }
      }
      await sink.close();
      _setState(ModelState.ready);
    } catch (e) {
      _setState(ModelState.notDownloaded);
      rethrow;
    }
  }

  void start() {
    _buffer.clear();
    _inSpeech = false;
    _silenceMs = 0;
    _running = true;
  }

  Future<void> stop() async {
    _running = false;
    if (_buffer.length > _minSegmentSamples) {
      await _flushSegment(finalSegment: true);
    }
    _buffer.clear();
  }

  static int get _minSegmentSamples =>
      _sampleRate * _minSegmentMs ~/ 1000;

  /// Приём PCM-чанка с ESP (через BLE).
  void ingest(Int16List samples) {
    if (!_running || _state != ModelState.ready && _state != ModelState.transcribing) {
      return;
    }

    final db = _rmsDb(samples);
    final chunkMs = samples.length * 1000 ~/ _sampleRate;

    if (db > _speechThresholdDb) {
      _inSpeech = true;
      _silenceMs = 0;
    } else if (_inSpeech) {
      _silenceMs += chunkMs;
    }

    if (_inSpeech) {
      _buffer.addAll(samples);
    }

    final bufferMs = _buffer.length * 1000 ~/ _sampleRate;
    final pauseDetected = _inSpeech && _silenceMs >= _silenceMsToFinalize;
    final tooLong = bufferMs >= _maxSegmentMs;

    if ((pauseDetected || tooLong) && _buffer.length > _minSegmentSamples) {
      _flushSegment(finalSegment: pauseDetected);
      _inSpeech = !pauseDetected;
      _silenceMs = 0;
    }
  }

  double _rmsDb(Int16List samples) {
    if (samples.isEmpty) return -120;
    var sum = 0.0;
    for (final s in samples) {
      sum += s * s;
    }
    final rms = sqrt(sum / samples.length) / 32768.0;
    if (rms <= 0) return -120;
    return 20 * log(rms) / ln10;
  }

  Future<void> _flushSegment({required bool finalSegment}) async {
    if (_busy) return; // сегмент подождёт следующего вызова
    final segment = Int16List.fromList(_buffer);
    _buffer.clear();
    _busy = true;
    _setState(ModelState.transcribing);

    try {
      final dir = await getTemporaryDirectory();
      final wavPath =
          '${dir.path}/seg_${DateTime.now().millisecondsSinceEpoch}.wav';
      await File(wavPath).writeAsBytes(pcmToWav(segment));

      final result = await _controller.transcribe(
        model: model,
        audioPath: wavPath,
        lang: 'auto',
        convert: false,
        withTimestamps: false,
        threads: 4,
      );

      final text = result?.transcription.text.trim() ?? '';
      if (text.isNotEmpty) {
        _segmentsController.add(
          TranscriptSegment(text, isFinal: finalSegment),
        );
      }

      File(wavPath).delete().ignore();
    } catch (_) {
      // Ошибка одного сегмента не должна ронять поток
    } finally {
      _busy = false;
      _setState(ModelState.ready);
    }
  }

  void dispose() {
    _running = false;
    _segmentsController.close();
    _modelStateController.close();
    _downloadProgress.close();
  }
}
