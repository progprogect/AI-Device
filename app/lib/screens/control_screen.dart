import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ai/model_registry.dart';
import '../ai/provider.dart';
import '../services/app_log.dart';
import '../services/esp_ble_service.dart';
import '../sources/audio_source.dart';
import '../sources/image_source.dart';
import 'local_photo_capture.dart';

/// Управление: запись → «Готово» → ASR → ответ LLM в чате.
class ControlScreen extends StatefulWidget {
  const ControlScreen({
    super.key,
    required this.title,
    required this.audioSource,
    required this.imageSource,
    this.ble,
    this.canDisconnect = true,
  });

  final String title;
  final AudioSource audioSource;
  final ImageSource imageSource;
  final EspBleService? ble;
  final bool canDisconnect;

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  final _registry = ModelRegistry.instance;
  final _log = AppLog.instance;

  bool _recording = false;
  bool _processing = false;
  bool _downloading = false;
  double _downloadProgress = 0;
  String _status = 'Готов';
  Uint8List? _lastPhoto;
  final List<ChatMessage> _chat = [];
  final ScrollController _chatScroll = ScrollController();
  StreamSubscription<String>? _llmSub;

  Map<String, ProviderAvailability> _asrAvail = {};
  Map<String, ProviderAvailability> _chatAvail = {};

  @override
  void initState() {
    super.initState();
    if (widget.imageSource is LocalImageSource) {
      (widget.imageSource as LocalImageSource).captureCallback =
          () => captureLocalPhoto(context);
    }
    _refreshAvailability();
  }

  Future<void> _refreshAvailability() async {
    final asr = <String, ProviderAvailability>{};
    for (final p in _registry.transcriptionProviders) {
      asr[p.id] = await p.checkAvailability();
    }
    final chat = <String, ProviderAvailability>{};
    for (final p in _registry.chatProviders) {
      chat[p.id] = await p.checkAvailability();
    }
    if (mounted) {
      if (widget.audioSource is EspAudioSource &&
          _registry.selectedTranscription.supportsLiveTranscription) {
        for (final p in _registry.transcriptionProviders) {
          if (p.supportsFileTranscription) {
            await _registry.selectTranscription(p);
            break;
          }
        }
      }
      setState(() {
        _asrAvail = asr;
        _chatAvail = chat;
        if (widget.audioSource is EspAudioSource) {
          _asrAvail['apple_speech'] = const ProviderAvailability(
            available: false,
            reason:
                'Apple Speech использует микрофон этого устройства, не ESP. Для ESP выберите Whisper.',
          );
        }
      });
    }
  }

  Future<void> _downloadWhisper() async {
    final wp = _registry.whisperProvider;
    if (wp == null) return;
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
    });
    try {
      await wp.downloadModel((p) {
        if (mounted) setState(() => _downloadProgress = p);
      });
      await _refreshAvailability();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Модель Whisper загружена')),
        );
      }
    } catch (e) {
      _log.error('Download failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка загрузки: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _toggleRecording() async {
    if (_processing) return;

    if (!_recording) {
      final asr = _registry.selectedTranscription;
      var liveStarted = false;
      try {
        if (asr.supportsLiveTranscription) {
          await asr.startLiveTranscription();
          liveStarted = true;
        }
        await widget.audioSource.startRecording();
        setState(() {
          _recording = true;
          _status = 'Запись…';
        });
      } catch (e) {
        if (liveStarted && asr.supportsLiveTranscription) {
          try {
            await asr.stopLiveTranscription();
          } catch (_) {}
        }
        _log.error('Start record: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Не удалось начать запись: $e')),
          );
        }
      }
      return;
    }

    // Стоп записи — ждём «Готово» для транскрипции
    try {
      final path = await widget.audioSource.stopRecording();
      _pendingWavPath = path;
      setState(() {
        _recording = false;
        _status = 'Запись остановлена — нажмите «Готово»';
      });
    } catch (e) {
      _log.error('Stop record: $e');
      setState(() {
        _recording = false;
        _status = 'Ошибка остановки записи';
      });
    }
  }

  String? _pendingWavPath;

  Future<void> _onDone() async {
    if (_processing) return;

    setState(() {
      _processing = true;
      _status = 'Транскрипция…';
    });

    try {
      final asr = _registry.selectedTranscription;
      String transcript;

      if (asr.supportsLiveTranscription) {
        if (_recording) {
          await widget.audioSource.stopRecording();
          setState(() => _recording = false);
        }
        transcript = await asr.stopLiveTranscription();
      } else {
        // Если запись ещё идёт — остановить и получить файл
        if (_recording) {
          _pendingWavPath = await widget.audioSource.stopRecording();
          setState(() => _recording = false);
        }
        final path = _pendingWavPath;
        _pendingWavPath = null;
        if (path == null || !File(path).existsSync()) {
          throw Exception('Нет записанного аудио');
        }
        transcript = await asr.transcribeFile(path, lang: 'auto');
      }

      transcript = transcript.trim();
      if (transcript.isEmpty) {
        setState(() => _status = 'Пустая транскрипция');
        return;
      }

      final userMsg = ChatMessage(role: ChatRole.user, content: transcript);
      setState(() {
        _chat.add(userMsg);
        _status = 'Ответ модели…';
      });
      _scrollChatToEnd();

      await _requestLlmResponse();
    } catch (e) {
      _log.error('Done pipeline: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
      setState(() => _status = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _requestLlmResponse() async {
    await _llmSub?.cancel();
    final chatProvider = _registry.selectedChat;
    final avail = await chatProvider.checkAvailability();
    if (!avail.available) {
      setState(() => _status = avail.reason ?? 'LLM недоступен');
      return;
    }

    final assistantMsg =
        ChatMessage(role: ChatRole.assistant, content: '');
    setState(() => _chat.add(assistantMsg));
    _scrollChatToEnd();

    try {
      final stream = chatProvider.respond(List.from(_chat));
      _llmSub = stream.listen(
        (chunk) {
          if (!mounted) return;
          setState(() {
            final idx = _chat.length - 1;
            _chat[idx] = ChatMessage(
              role: ChatRole.assistant,
              content: _chat[idx].content + chunk,
              time: _chat[idx].time,
            );
          });
          _scrollChatToEnd();
        },
        onError: (e) {
          _log.error('LLM: $e');
          if (mounted) {
            setState(() {
              final idx = _chat.length - 1;
              _chat[idx] = ChatMessage(
                role: ChatRole.assistant,
                content: 'Ошибка: $e',
                time: _chat[idx].time,
              );
            });
          }
        },
        onDone: () {
          if (mounted) setState(() => _status = 'Готов');
        },
      );
    } catch (e) {
      _log.error('LLM start: $e');
      setState(() => _status = 'Ошибка LLM: $e');
    }
  }

  Future<void> _capturePhoto() async {
    setState(() => _status = 'Съёмка…');
    try {
      final bytes = await widget.imageSource.capturePhoto();
      if (bytes != null && mounted) {
        setState(() {
          _lastPhoto = bytes;
          _status = 'Фото получено (${bytes.length} байт)';
        });
      } else {
        setState(() => _status = 'Фото не получено');
      }
    } catch (e) {
      _log.error('Photo: $e');
      setState(() => _status = 'Ошибка фото: $e');
    }
  }

  void _scrollChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _disconnect() async {
    await _llmSub?.cancel();
    widget.audioSource.dispose();
    await widget.ble?.disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _llmSub?.cancel();
    _chatScroll.dispose();
    widget.audioSource.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final whisperReady =
        _registry.whisperProvider != null &&
            (_asrAvail[_registry.whisperProvider!.id]?.available ?? false);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (widget.canDisconnect && widget.ble != null)
            IconButton(
              icon: const Icon(Icons.link_off),
              tooltip: 'Отключиться',
              onPressed: _disconnect,
            ),
        ],
      ),
      body: Column(
        children: [
          _buildProviderBar(),
          if (!whisperReady && _registry.whisperProvider != null)
            _buildDownloadBar(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Icon(
                  _recording ? Icons.fiber_manual_record : Icons.circle_outlined,
                  color: _recording ? Colors.red : Colors.grey,
                  size: 14,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(_status, style: const TextStyle(fontSize: 13))),
              ],
            ),
          ),
          Expanded(child: _buildChat()),
          if (_lastPhoto != null) _buildPhotoPreview(),
          _buildControls(),
          _buildLogPanel(),
        ],
      ),
    );
  }

  Widget _buildProviderBar() {
    final asrList = _registry.transcriptionProviders;
    final chatList = _registry.chatProviders;

    return Material(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<TranscriptionProvider>(
                decoration: const InputDecoration(
                  labelText: 'ASR',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                value: asrList.contains(_registry.selectedTranscription)
                    ? _registry.selectedTranscription
                    : (asrList.isNotEmpty ? asrList.first : null),
                items: asrList.map((p) {
                  final avail = _asrAvail[p.id];
                  final suffix = avail?.available == true ? '' : ' ⚠';
                  return DropdownMenuItem(
                    value: p,
                    child: Text('${p.displayName}$suffix'),
                  );
                }).toList(),
                onChanged: (p) async {
                  if (p == null) return;
                  await _registry.selectTranscription(p);
                  setState(() {});
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<ChatProvider>(
                decoration: const InputDecoration(
                  labelText: 'Chat LLM',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                value: chatList.contains(_registry.selectedChat)
                    ? _registry.selectedChat
                    : (chatList.isNotEmpty ? chatList.first : null),
                items: chatList.map((p) {
                  final avail = _chatAvail[p.id];
                  final suffix = avail?.available == true ? '' : ' ⚠';
                  return DropdownMenuItem(
                    value: p,
                    child: Text('${p.displayName}$suffix'),
                  );
                }).toList(),
                onChanged: (p) async {
                  if (p == null) return;
                  await _registry.selectChat(p);
                  setState(() {});
                },
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Обновить доступность',
              onPressed: _refreshAvailability,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: _downloading
                ? LinearProgressIndicator(value: _downloadProgress)
                : const Text('Whisper: модель не загружена'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _downloading ? null : _downloadWhisper,
            child: Text(_downloading ? 'Загрузка…' : 'Скачать модель'),
          ),
        ],
      ),
    );
  }

  Widget _buildChat() {
    if (_chat.isEmpty) {
      return Center(
        child: Text(
          'Источник: ${widget.audioSource.label}\n'
          'Запишите голос → «Готово» → ответ в чате',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade600),
        ),
      );
    }

    return ListView.builder(
      controller: _chatScroll,
      padding: const EdgeInsets.all(12),
      itemCount: _chat.length,
      itemBuilder: (context, i) {
        final msg = _chat[i];
        final isUser = msg.role == ChatRole.user;
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            decoration: BoxDecoration(
              color: isUser
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isUser ? 'Вы' : 'Ассистент',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 4),
                Text(msg.content.isEmpty ? '…' : msg.content),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPhotoPreview() {
    return SizedBox(
      height: 120,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(_lastPhoto!, height: 100, fit: BoxFit.cover),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: _processing ? null : _toggleRecording,
            icon: Icon(_recording ? Icons.stop : Icons.mic),
            label: Text(_recording ? 'Стоп' : 'Запись'),
          ),
          FilledButton.icon(
            onPressed: (_processing || _recording) ? null : _onDone,
            icon: const Icon(Icons.check),
            label: const Text('Готово'),
          ),
          OutlinedButton.icon(
            onPressed: _processing ? null : _capturePhoto,
            icon: const Icon(Icons.photo_camera),
            label: const Text('Фото'),
          ),
          OutlinedButton.icon(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Video — скоро')),
              );
            },
            icon: const Icon(Icons.videocam),
            label: const Text('Video (скоро)'),
          ),
        ],
      ),
    );
  }

  Widget _buildLogPanel() {
    return SizedBox(
      height: 100,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          border: Border(top: BorderSide(color: Colors.grey.shade700)),
        ),
        child: StreamBuilder<List<String>>(
          stream: _log.lines,
          initialData: _log.snapshot,
          builder: (context, snapshot) {
            final lines = snapshot.data ?? _log.snapshot;
            return ListView.builder(
              reverse: true,
              padding: const EdgeInsets.all(8),
              itemCount: lines.length,
              itemBuilder: (_, i) => Text(
                lines[lines.length - 1 - i],
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Colors.greenAccent,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
