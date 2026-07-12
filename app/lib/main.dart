import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ai/model_registry.dart';
import 'screens/start_screen.dart';
import 'services/app_log.dart';
import 'services/esp_ble_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.instance.init();
  await ModelRegistry.instance.init();
  FlutterBluePlus.setLogLevel(
    kReleaseMode ? LogLevel.info : LogLevel.verbose,
  );
  AppLog.instance.info('ESP Sense starting');
  runApp(const EspSenseApp());
}

class EspSenseApp extends StatefulWidget {
  const EspSenseApp({super.key});

  @override
  State<EspSenseApp> createState() => _EspSenseAppState();
}

class _EspSenseAppState extends State<EspSenseApp> {
  final _ble = EspBleService();

  @override
  void dispose() {
    _ble.dispose();
    AppLog.instance.dispose();
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
      home: StartScreen(ble: _ble),
    );
  }
}
