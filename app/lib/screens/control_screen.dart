import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/esp_ble_service.dart';
import '../services/transcription_service.dart';

class ControlScreen extends StatefulWidget {
  const ControlScreen({
    super.key,
    required this.ble,
    required this.transcription,
  });

  final EspBleService ble;
  final TranscriptionService transcription;

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  bool _recording = false;
  bool _photoInFlight = false;
  Uint8List? _lastImage;
  DateTime? _lastImageTime;

  ModelState _modelState = ModelState.notDownloaded;
  double _downloadProgress = 0;

  final List<TranscriptSegment> _finalSegments = [];
  String _partialText = '';

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();

    _subs.add(widget.ble.audioStream.listen(widget.transcription.ingest));

    _subs.add(widget.ble.imageStream.listen((jpeg) {
      setState(() {
        _lastImage = jpeg;
        _lastImageTime = DateTime.now();
        _photoInFlight = false;
      });
    }));

    _subs.add(widget.ble.connectionState.listen((s) {
      if (s == EspConnectionState.disconnected && mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    }));

    _subs.add(widget.transcription.segments.listen((seg) {
      setState(() {
        if (seg.isFinal) {
          _finalSegments.add(seg);
          _partialText = '';
        } else {
          _partialText = seg.text;
        }
      });
    }));

    _subs.add(widget.transcription.modelState.listen((s) {
      if (mounted) setState(() => _modelState = s);
    }));

    _subs.add(widget.transcription.downloadProgress.listen((p) {
      if (mounted) setState(() => _downloadProgress = p);
    }));

    widget.transcription.isModelDownloaded();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      await widget.ble.stopAudio();
      await widget.transcription.stop();
      setState(() => _recording = false);
    } else {
      widget.transcription.start();
      await widget.ble.startAudio();
      setState(() => _recording = true);
    }
  }

  Future<void> _capturePhoto() async {
    setState(() => _photoInFlight = true);
    await widget.ble.capturePhoto();
    // Сброс, если фото не пришло за 90 с
    Timer(const Duration(seconds: 90), () {
      if (mounted && _photoInFlight) {
        setState(() => _photoInFlight = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.ble.deviceInfo;
    final modelReady = _modelState == ModelState.ready ||
        _modelState == ModelState.transcribing;

    return Scaffold(
      appBar: AppBar(
        title: Text('ESP-Sense · fw ${info.firmware}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bluetooth_disabled),
            tooltip: 'Отключиться',
            onPressed: () => widget.ble.disconnect(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildModelCard(modelReady),
          const SizedBox(height: 12),
          _buildControls(modelReady),
          const SizedBox(height: 12),
          _buildPhotoCard(),
          const SizedBox(height: 12),
          _buildTranscriptCard(),
        ],
      ),
    );
  }

  Widget _buildModelCard(bool modelReady) {
    if (modelReady) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Модель Whisper (large-v3-turbo, ~574 МБ)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_modelState == ModelState.downloading) ...[
              LinearProgressIndicator(value: _downloadProgress),
              const SizedBox(height: 8),
              Text('${(_downloadProgress * 100).toStringAsFixed(0)} %'),
            ] else
              FilledButton.icon(
                onPressed: () => widget.transcription.downloadModel(),
                icon: const Icon(Icons.download),
                label: const Text('Скачать модель (нужен Wi-Fi)'),
              ),
            const SizedBox(height: 4),
            const Text(
              'Скачивается один раз и сохраняется при обновлениях приложения.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(bool modelReady) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _recording ? Colors.red : null,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: modelReady ? _toggleRecording : null,
                icon: Icon(_recording ? Icons.stop : Icons.mic),
                label: Text(_recording ? 'Стоп' : 'Старт'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: _photoInFlight ? null : _capturePhoto,
                icon: _photoInFlight
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.photo_camera),
                label: Text(_photoInFlight ? 'Приём…' : 'Фото'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Последний снимок',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_lastImage != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  _lastImage!,
                  gaplessPlayback: true,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) =>
                      const Text('Не удалось декодировать JPEG'),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Получен: ${_lastImageTime!.hour.toString().padLeft(2, '0')}:'
                '${_lastImageTime!.minute.toString().padLeft(2, '0')}:'
                '${_lastImageTime!.second.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ] else
              const Text('Нажмите «Фото», чтобы получить снимок с камеры',
                  style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildTranscriptCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Расшифровка',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_modelState == ModelState.transcribing)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_finalSegments.isEmpty && _partialText.isEmpty)
              const Text(
                'Нажмите «Старт» и говорите — текст появится здесь.',
                style: TextStyle(color: Colors.grey),
              ),
            for (final seg in _finalSegments)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(seg.text),
              ),
            if (_partialText.isNotEmpty)
              Text(_partialText,
                  style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
