import 'package:flutter/material.dart';

import 'connect_screen.dart';
import 'control_screen.dart';
import '../services/esp_ble_service.dart';
import '../sources/audio_source.dart';
import '../sources/image_source.dart';

/// Стартовый экран: ESP-устройство или локальный режим без девайса.
class StartScreen extends StatelessWidget {
  const StartScreen({super.key, this.ble});

  final EspBleService? ble;

  @override
  Widget build(BuildContext context) {
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
                'Выберите режим работы',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: 320,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ConnectScreen(ble: ble),
                      ),
                    );
                  },
                  icon: const Icon(Icons.bluetooth),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Подключиться к ESP-устройству'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 320,
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ControlScreen(
                          title: 'Локальный режим',
                          audioSource: LocalAudioSource(),
                          imageSource: LocalImageSource(),
                          canDisconnect: false,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.mic),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Без устройства (микрофон / камера ПК)'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
