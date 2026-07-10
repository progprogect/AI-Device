import 'package:flutter/material.dart';

import 'screens/connect_screen.dart';
import 'services/esp_ble_service.dart';
import 'services/transcription_service.dart';

void main() {
  runApp(const EspSenseApp());
}

class EspSenseApp extends StatefulWidget {
  const EspSenseApp({super.key});

  @override
  State<EspSenseApp> createState() => _EspSenseAppState();
}

class _EspSenseAppState extends State<EspSenseApp> {
  final _ble = EspBleService();
  final _transcription = TranscriptionService();

  @override
  void dispose() {
    _ble.dispose();
    _transcription.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP Sense',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: ConnectScreen(ble: _ble, transcription: _transcription),
    );
  }
}
