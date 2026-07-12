import '../provider.dart';

/// Задел: OpenAI-compatible API (требует API-ключ в ModelRegistry).
class OpenAiCompatibleProvider implements ChatProvider {
  OpenAiCompatibleProvider({
    required this.baseUrl,
    required this.modelName,
    required this.apiKey,
  });

  final String baseUrl;
  final String modelName;
  final String? apiKey;

  @override
  String get id => 'openai_compatible';

  @override
  String get displayName => 'OpenAI-compatible ($modelName)';

  bool get requiresApiKey => true;

  @override
  Future<ProviderAvailability> checkAvailability() async {
    if (apiKey == null || apiKey!.isEmpty) {
      return const ProviderAvailability(
        available: false,
        reason: 'Добавьте API-ключ в настройках (будущая версия).',
      );
    }
    return const ProviderAvailability(
      available: false,
      reason: 'Провайдер зарезервирован — реализация в следующей версии.',
    );
  }

  @override
  Stream<String> respond(List<ChatMessage> history) async* {
    final avail = await checkAvailability();
    throw Exception(avail.reason ?? 'OpenAI-compatible провайдер недоступен');
  }
}
