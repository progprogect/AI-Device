import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/app_log.dart';
import '../services/esp_ble_service.dart';
import '../services/transcription_service.dart';
import 'control_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({
    super.key,
    required this.ble,
    required this.transcription,
  });

  final EspBleService ble;
  final TranscriptionService transcription;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  String? _error;
  EspConnectionState _state = EspConnectionState.disconnected;
  List<String> _logLines = AppLog.instance.snapshot;

  @override
  void initState() {
    super.initState();
    widget.ble.connectionState.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    AppLog.instance.lines.listen((lines) {
      if (mounted) setState(() => _logLines = lines);
    });
  }

  Future<bool> _requestBlePermissions() async {
    if (kIsWeb || !Platform.isAndroid) return true;

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    if (statuses.values.any((s) => s.isPermanentlyDenied)) {
      setState(() => _error =
          'Нет разрешения на Bluetooth. Включите его в настройках устройства.');
      return false;
    }
    return true;
  }

  String _formatError(Object e) {
    final raw = e.toString();
    if (raw.contains('PlatformException')) {
      if (raw.contains('CBManagerStateUnknown') ||
          raw.contains('bluetooth must be turned on')) {
        return 'Bluetooth ещё инициализируется. Подождите 2 сек и нажмите снова.\n'
            'Если повторяется: Системные настройки → Bluetooth — включён; '
            'Конфиденциальность → Bluetooth — разрешите ESP Sense.';
      }
      if (raw.contains('CBManagerStatePoweredOff') || raw.contains('off')) {
        return 'Bluetooth выключен. Включите в Системных настройках → Bluetooth.';
      }
      if (raw.contains('unauthorized')) {
        return 'Нет доступа к Bluetooth. Настройки → Конфиденциальность → Bluetooth.';
      }
    }
    return raw
        .replaceFirst('Exception: ', '')
        .replaceFirst('PlatformException(', '')
        .replaceAll(RegExp(r'\), null, null\)$'), '');
  }

  Future<void> _connect() async {
    setState(() => _error = null);
    AppLog.instance.info('User tapped Connect');

    if (!await _requestBlePermissions()) return;

    try {
      await widget.ble.connect();
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ControlScreen(
            ble: widget.ble,
            transcription: widget.transcription,
          ),
        ),
      );
    } catch (e) {
      AppLog.instance.error('Connect UI error', e);
      setState(() => _error = _formatError(e));
    }
  }

  void _showLogs() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.85,
        minChildSize: 0.3,
        builder: (_, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Text('Логи',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: AppLog.instance.fullText));
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('Логи скопированы')),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Копировать'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.all(12),
                itemCount: _logLines.length,
                itemBuilder: (_, i) => SelectableText(
                  _logLines[i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = _state == EspConnectionState.scanning ||
        _state == EspConnectionState.connecting;

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.sensors, size: 96, color: Colors.teal),
              const SizedBox(height: 16),
              Text('ESP Sense',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                busy
                    ? (_state == EspConnectionState.scanning
                        ? 'Поиск устройства…'
                        : 'Подключение…')
                    : 'Подключитесь к устройству по Bluetooth',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 32),
              if (busy)
                const CircularProgressIndicator()
              else
                FilledButton.icon(
                  onPressed: _connect,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('Подключиться'),
                ),
              if (_error != null) ...[
                const SizedBox(height: 24),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              TextButton.icon(
                onPressed: _showLogs,
                icon: const Icon(Icons.article_outlined, size: 18),
                label: Text('Логи (${_logLines.length})'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
