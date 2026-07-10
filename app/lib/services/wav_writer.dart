import 'dart:typed_data';

/// PCM 16 бит моно → WAV-байты.
Uint8List pcmToWav(Int16List samples, {int sampleRate = 16000}) {
  final dataSize = samples.length * 2;
  final bytes = ByteData(44 + dataSize);

  void writeString(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeString(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little); // PCM
  bytes.setUint16(22, 1, Endian.little); // mono
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  writeString(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    bytes.setInt16(44 + i * 2, samples[i], Endian.little);
  }

  return bytes.buffer.asUint8List();
}
