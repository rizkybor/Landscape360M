import 'package:audioplayers/audioplayers.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:torch_light/torch_light.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../domain/sos/siren.dart';

// The phone's parts the S.O.S screen uses: battery level, keeping the screen on, the LED
// torch and the siren. Everything works without internet; tests use a fake.

abstract interface class SosDevice {
  /// Battery in percent, or null when the phone does not tell
  Future<int?> battery();
  Future<void> keepScreenOn(bool on);
  Future<bool> hasTorch();
  Future<void> torch(bool on);
  Future<void> siren(bool on);
}

class PhoneSosDevice implements SosDevice {
  AudioPlayer? _player;

  @override
  Future<int?> battery() async {
    try {
      return await Battery().batteryLevel;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> keepScreenOn(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } on Object {
      // Not allowed: S.O.S still works, the screen may dim
    }
  }

  @override
  Future<bool> hasTorch() async {
    try {
      return await TorchLight.isTorchAvailable();
    } on Object {
      return false;
    }
  }

  @override
  Future<void> torch(bool on) async {
    try {
      on ? await TorchLight.enableTorch() : await TorchLight.disableTorch();
    } on Object {
      // Torch busy or missing: the white screen still flashes
    }
  }

  @override
  Future<void> siren(bool on) async {
    if (!on) {
      await _player?.stop();
      await _player?.dispose();
      _player = null;
      return;
    }
    // iOS: the playback category plays even with the silent switch on
    final player = _player ??= AudioPlayer();
    await player.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
        android: const AudioContextAndroid(
          usageType: AndroidUsageType.alarm,
          contentType: AndroidContentType.sonification,
        ),
      ),
    );
    await player.setReleaseMode(ReleaseMode.loop);
    await player.setVolume(1);
    await player.play(BytesSource(buildSirenWav(), mimeType: 'audio/wav'));
  }
}
