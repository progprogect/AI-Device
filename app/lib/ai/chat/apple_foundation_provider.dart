import 'package:flutter_foundation_models/flutter_foundation_models.dart';

import '../provider.dart';
import '../../services/app_log.dart';

class AppleFoundationProvider implements ChatProvider {
  LanguageModelSession? _session;
  final _log = AppLog.instance;

  @override
  String get id => 'apple_foundation';

  @override
  String get displayName => 'Apple Foundation Models';

  @override
  Future<ProviderAvailability> checkAvailability() async {
    final avail = await SystemLanguageModel.availability;
    if (avail.isAvailable) return ProviderAvailability.ready;
    return ProviderAvailability(
      available: false,
      reason: avail.unavailableReason ??
          'Foundation Models недоступны. Включите Apple Intelligence.',
    );
  }

  Future<LanguageModelSession> _sessionOrCreate() async {
    _session ??= await LanguageModelSession.create(
      instructions:
          'Ты полезный ассистент. Отвечай кратко и по делу на языке пользователя.',
    );
    return _session!;
  }

  @override
  Stream<String> respond(List<ChatMessage> history) async* {
    final avail = await checkAvailability();
    if (!avail.available) {
      throw Exception(avail.reason ?? 'Apple Foundation Models недоступны');
    }

    final lastUser = history.lastWhere(
      (m) => m.role == ChatRole.user,
      orElse: () => ChatMessage(role: ChatRole.user, content: ''),
    );
    if (lastUser.content.isEmpty) {
      yield 'Нет текста для ответа.';
      return;
    }

    // Контекст предыдущих реплик в промпте
    final contextLines = history
        .where((m) => m != lastUser)
        .map((m) => '${m.role.name}: ${m.content}')
        .join('\n');
    final prompt = contextLines.isEmpty
        ? lastUser.content
        : '$contextLines\nuser: ${lastUser.content}\nassistant:';

    _log.info('Apple FM prompt (${prompt.length} chars)');
    final session = await _sessionOrCreate();

    yield* session.streamResponseTo(prompt);
  }

  void dispose() {
    _session?.dispose();
    _session = null;
  }
}
