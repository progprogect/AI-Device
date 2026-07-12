import 'dart:io';

import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import '../provider.dart';
import '../../services/app_log.dart';

class WhisperProvider extends TranscriptionProvider {
  WhisperProvider({this.model = WhisperModel.largeV3Turbo});

  final WhisperModel model;
  final WhisperController _controller = WhisperController();
  final _log = AppLog.instance;

  @override
  String get id => 'whisper_large_turbo';

  @override
  String get displayName => 'Whisper ${model.modelName}';

  @override
  bool get supportsFileTranscription => true;

  @override
  bool get supportsLiveTranscription => false;

  @override
  Future<ProviderAvailability> checkAvailability() async {
    final path = await _controller.getPath(model);
    if (File(path).existsSync()) {
      return ProviderAvailability.ready;
    }
    return const ProviderAvailability(
      available: false,
      reason: 'Модель не скачана. Нажмите «Скачать модель».',
    );
  }

  Future<void> downloadModel(void Function(double progress) onProgress) async {
    final path = await _controller.getPath(model);
    if (File(path).existsSync()) return;

    final uri = model.modelUri;
    final request = await HttpClient().getUrl(uri);
    final response = await request.close();
    final total = response.contentLength;
    var received = 0;
    final file = File(path);
    final sink = file.openWrite();
    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress(received / total);
    }
    await sink.close();
  }

  @override
  Future<String> transcribeFile(String wavPath, {String lang = 'auto'}) async {
    _log.info('Whisper transcribe: $wavPath');
    final avail = await checkAvailability();
    if (!avail.available) {
      throw Exception(avail.reason ?? 'Whisper недоступен');
    }

    final result = await _controller.transcribe(
      model: model,
      audioPath: wavPath,
      lang: lang,
      convert: false,
      withTimestamps: false,
      threads: 4,
    );
    return result?.transcription.text.trim() ?? '';
  }
}
