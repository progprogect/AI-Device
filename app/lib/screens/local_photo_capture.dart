import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'camera_capture_dialog.dart';

/// Захват фото: camera_macos на macOS, image_picker на iOS/Android.
Future<Uint8List?> captureLocalPhoto(BuildContext context) async {
  if (Platform.isMacOS) {
    return showMacCameraCaptureDialog(context);
  }

  final picker = ImagePicker();
  final file = await picker.pickImage(source: ImageSource.camera);
  if (file == null) return null;
  return file.readAsBytes();
}
