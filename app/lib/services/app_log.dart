import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Логи приложения: буфер в памяти + файл (для macOS .app без терминала).
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int _maxLines = 200;

  final List<String> _lines = [];
  final _controller = StreamController<List<String>>.broadcast();
  File? _file;
  bool _fileReady = false;

  Stream<List<String>> get lines => _controller.stream;
  List<String> get snapshot => List.unmodifiable(_lines);

  Future<void> init() async {
    if (_fileReady) return;
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      _file = File('${dir.path}/esp_sense.log');
      _fileReady = true;
      info('AppLog initialized: ${_file!.path}');
    } catch (e) {
      debugPrint('AppLog init failed: $e');
    }
  }

  void info(String msg) => _write('INFO', msg);
  void warn(String msg) => _write('WARN', msg);
  void error(String msg, [Object? err]) {
    final detail = err != null ? '$msg: $err' : msg;
    _write('ERROR', detail);
  }

  void _write(String level, String msg) {
    final line =
        '${DateTime.now().toIso8601String().substring(11, 23)} [$level] $msg';
    _lines.add(line);
    if (_lines.length > _maxLines) {
      _lines.removeAt(0);
    }
    debugPrint(line);
    _controller.add(snapshot);
    _appendToFile(line);
  }

  Future<void> _appendToFile(String line) async {
    if (!_fileReady || _file == null) return;
    try {
      await _file!.writeAsString('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  String get fullText => _lines.join('\n');

  void dispose() {
    _controller.close();
  }
}
