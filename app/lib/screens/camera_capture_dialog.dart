import 'dart:typed_data';

import 'package:camera_macos/camera_macos.dart';
import 'package:flutter/material.dart';

/// Диалог с превью камеры Mac для съёмки фото.
Future<Uint8List?> showMacCameraCaptureDialog(BuildContext context) {
  return showDialog<Uint8List?>(
    context: context,
    builder: (ctx) => const _CameraDialog(),
  );
}

class _CameraDialog extends StatefulWidget {
  const _CameraDialog();

  @override
  State<_CameraDialog> createState() => _CameraDialogState();
}

class _CameraDialogState extends State<_CameraDialog> {
  CameraMacOSController? _controller;
  bool _busy = false;
  String? _error;

  Future<void> _takePhoto() async {
    final c = _controller;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      final file = await c.takePicture();
      if (!mounted) return;
      if (file != null && file.bytes != null) {
        Navigator.of(context).pop(file.bytes);
      } else {
        setState(() => _error = 'Не удалось получить фото');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Сделать фото'),
      content: SizedBox(
        width: 480,
        height: 360,
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CameraMacOSView(
                  cameraMode: CameraMacOSMode.photo,
                  onCameraInizialized: (controller) {
                    setState(() => _controller = controller);
                  },
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _controller == null || _busy ? null : _takePhoto,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.camera_alt),
          label: const Text('Снять'),
        ),
      ],
    );
  }
}
