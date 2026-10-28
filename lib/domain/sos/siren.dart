import 'dart:math' as math;
import 'dart:typed_data';

// The S.O.S siren of the web (useSiren in SosScreen.tsx) as a WAV made on the phone, so it
// plays without internet: three long square-wave tones rising 900 → 1500 Hz, 1.1 s apart,
// then quiet until the 4.5 s loop starts again.

const sirenSampleRate = 22050;
const sirenLoopSeconds = 4.5;

Uint8List buildSirenWav({int sampleRate = sirenSampleRate}) {
  final samples = (sirenLoopSeconds * sampleRate).round();
  final pcm = Int16List(samples);
  for (var blast = 0; blast < 3; blast++) {
    final start = blast * 1.1;
    var phase = 0.0;
    for (var i = (start * sampleRate).round(); i < ((start + 0.95) * sampleRate).round() && i < samples; i++) {
      final t = i / sampleRate - start;
      final freq = t < 0.8 ? 900 + 600 * t / 0.8 : 1500.0;
      phase += freq / sampleRate;
      // Envelope: quick rise, hold, short fade (no clicks)
      final gain = t < 0.05
          ? t / 0.05
          : t < 0.8
          ? 1.0
          : math.max(0.0, 1 - (t - 0.8) / 0.1);
      final square = (phase % 1) < 0.5 ? 1.0 : -1.0;
      pcm[i] = (square * gain * 0.6 * 32767).round();
    }
  }
  return _wav(pcm, sampleRate);
}

Uint8List _wav(Int16List pcm, int sampleRate) {
  final data = pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
  final b = ByteData(44);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + data.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b
    ..setUint32(16, 16, Endian.little) // PCM header size
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little) // bytes per second
    ..setUint16(32, 2, Endian.little) // bytes per sample
    ..setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  b.setUint32(40, data.length, Endian.little);
  return Uint8List.fromList([...b.buffer.asUint8List(), ...data]);
}
