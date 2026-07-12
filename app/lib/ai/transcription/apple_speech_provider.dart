import 'package:liquid_speech/liquid_speech.dart';

import '../provider.dart';
import '../../services/app_log.dart';

/// Apple SpeechAnalyzer — live-транскрипция во время записи (macOS/iOS 26+).
class AppleSpeechProvider extends TranscriptionProvider {
  AppleSpeechProvider() : _service = SpeechAnalyzerService();

  final SpeechAnalyzerService _service;
  final _log = AppLog.instance;

  @override
  String get id => 'apple_speech';

  @override
  String get displayName => 'Apple Speech (SpeechAnalyzer)';

  @override
  bool get supportsFileTranscription => false;

  @override
  bool get supportsLiveTranscription => true;

  @override
  Future<ProviderAvailability> checkAvailability() async {
    final ok = await _service.isAvailable();
    if (ok) return ProviderAvailability.ready;
    return const ProviderAvailability(
      available: false,
      reason:
          'SpeechAnalyzer недоступен. Нужны macOS/iOS 26+ и Apple Intelligence.',
    );
  }

  @override
  Future<void> startLiveTranscription() async {
    _log.info('Apple Speech: start live');
    final ok = await _service.startTranscription();
    if (!ok) {
      throw Exception('Не удалось запустить Apple Speech');
    }
  }

  @override
  Future<String> stopLiveTranscription() async {
    _log.info('Apple Speech: stop live');
    final text = await _service.stopTranscription();
    return text?.trim() ?? '';
  }

  void dispose() => _service.dispose();
}
