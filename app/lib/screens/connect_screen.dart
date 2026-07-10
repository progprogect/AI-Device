import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

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

  @override
  void initState() {
    super.initState();
    widget.ble.connectionState.listen((s) {
      if (mounted) setState(() => _state = s);
    });
  }

  Future<void> _connect() async {
    setState(() => _error = null);

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    if (statuses.values.any((s) => s.isPermanentlyDenied)) {
      setState(() => _error =
          'Нет разрешения на Bluetooth. Включите его в настройках телефона.');
      return;
    }

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
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
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
            ],
          ),
        ),
      ),
    );
  }
}
