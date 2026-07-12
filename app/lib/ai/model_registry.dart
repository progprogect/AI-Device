import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import 'chat/apple_foundation_provider.dart';
import 'chat/openai_compatible_provider.dart';
import 'provider.dart';
import 'transcription/apple_speech_provider.dart';
import 'transcription/whisper_provider.dart';
import '../services/app_log.dart';

/// Реестр ASR и Chat-провайдеров из assets/models.json.
class ModelRegistry {
  ModelRegistry._();
  static final ModelRegistry instance = ModelRegistry._();

  final _log = AppLog.instance;

  final List<TranscriptionProvider> _transcription = [];
  final List<ChatProvider> _chat = [];

  TranscriptionProvider? _selectedTranscription;
  ChatProvider? _selectedChat;

  WhisperProvider? _whisperProvider;

  List<TranscriptionProvider> get transcriptionProviders =>
      List.unmodifiable(_transcription);
  List<ChatProvider> get chatProviders => List.unmodifiable(_chat);

  TranscriptionProvider get selectedTranscription {
    if (_selectedTranscription != null) return _selectedTranscription!;
    if (_transcription.isNotEmpty) return _transcription.first;
    throw StateError('Нет ASR-провайдеров');
  }

  ChatProvider get selectedChat {
    if (_selectedChat != null) return _selectedChat!;
    if (_chat.isNotEmpty) return _chat.first;
    throw StateError('Нет Chat-провайдеров');
  }

  WhisperProvider? get whisperProvider => _whisperProvider;

  Future<void> init() async {
    final raw = await rootBundle.loadString('assets/models.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final prefs = await SharedPreferences.getInstance();

    _transcription.clear();
    _chat.clear();

    for (final entry in json['transcription'] as List) {
      if (entry['enabled'] != true) continue;
      final p = _createTranscription(entry as Map<String, dynamic>);
      if (p != null) _transcription.add(p);
    }

    for (final entry in json['chat'] as List) {
      if (entry['enabled'] != true) continue;
      final p = await _createChat(entry as Map<String, dynamic>, prefs);
      if (p != null) _chat.add(p);
    }

    if (_transcription.isEmpty) {
      _whisperProvider = WhisperProvider();
      _transcription.add(_whisperProvider!);
    }

    final savedAsr = prefs.getString('selected_asr_id');
    _selectedTranscription = _findById(_transcription, savedAsr) ??
        (_transcription.isNotEmpty ? _transcription.first : null);

    final savedChat = prefs.getString('selected_chat_id');
    _selectedChat =
        _findById(_chat, savedChat) ?? (_chat.isNotEmpty ? _chat.first : null);

    _log.info(
        'ModelRegistry: ${_transcription.length} ASR, ${_chat.length} chat');
  }

  TranscriptionProvider? _createTranscription(Map<String, dynamic> entry) {
    switch (entry['type'] as String) {
      case 'whisper':
        final modelName = entry['config']?['model'] as String? ?? 'large-v3-turbo';
        final model = WhisperModel.values.firstWhere(
          (m) => m.modelName == modelName,
          orElse: () => WhisperModel.largeV3Turbo,
        );
        _whisperProvider = WhisperProvider(model: model);
        return _whisperProvider;
      case 'apple_speech':
        return AppleSpeechProvider();
      default:
        _log.warn('Unknown transcription type: ${entry['type']}');
        return null;
    }
  }

  Future<ChatProvider?> _createChat(
    Map<String, dynamic> entry,
    SharedPreferences prefs,
  ) async {
    switch (entry['type'] as String) {
      case 'apple_foundation':
        return AppleFoundationProvider();
      case 'openai_compatible':
        final apiKey = prefs.getString('api_key_${entry['id']}');
        final config = entry['config'] as Map<String, dynamic>? ?? {};
        return OpenAiCompatibleProvider(
          baseUrl: config['baseUrl'] as String? ?? 'https://api.openai.com/v1',
          modelName: config['model'] as String? ?? 'gpt-4o-mini',
          apiKey: apiKey,
        );
      default:
        _log.warn('Unknown chat type: ${entry['type']}');
        return null;
    }
  }

  Future<void> selectTranscription(TranscriptionProvider provider) async {
    _selectedTranscription = provider;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_asr_id', provider.id);
  }

  Future<void> selectChat(ChatProvider provider) async {
    _selectedChat = provider;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_chat_id', provider.id);
  }

  Future<void> setApiKey(String providerId, String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key_$providerId', key);
    await init();
  }

  T? _findById<T extends Object>(List<T> list, String? id) {
    if (id == null) return null;
    for (final item in list) {
      if (item is TranscriptionProvider && item.id == id) return item as T;
      if (item is ChatProvider && item.id == id) return item as T;
    }
    return null;
  }
}
