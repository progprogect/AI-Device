/// Роли и контракты провайдеров AI (ASR + Chat).
library;

enum ChatRole { user, assistant, system }

class ChatMessage {
  final ChatRole role;
  final String content;
  final DateTime time;

  ChatMessage({
    required this.role,
    required this.content,
    DateTime? time,
  }) : time = time ?? DateTime.now();
}

class ProviderAvailability {
  final bool available;
  final String? reason;

  const ProviderAvailability({required this.available, this.reason});

  static const ready = ProviderAvailability(available: true);
}

/// Распознавание речи (batch и/или live).
abstract class TranscriptionProvider {
  String get id;
  String get displayName;

  bool get supportsFileTranscription => true;
  bool get supportsLiveTranscription => false;

  Future<ProviderAvailability> checkAvailability();

  Future<String> transcribeFile(String wavPath, {String lang = 'auto'}) {
    throw UnsupportedError('$displayName не поддерживает transcribeFile');
  }

  Future<void> startLiveTranscription() {
    throw UnsupportedError('$displayName не поддерживает live-транскрипцию');
  }

  Future<String> stopLiveTranscription() {
    throw UnsupportedError('$displayName не поддерживает live-транскрипцию');
  }
}

/// LLM для ответа в чате.
abstract class ChatProvider {
  String get id;
  String get displayName;

  Future<ProviderAvailability> checkAvailability();

  Stream<String> respond(List<ChatMessage> history);
}
