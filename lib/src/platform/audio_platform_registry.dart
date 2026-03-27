import 'dart:io' show Platform;

import 'audio_platform.dart';
import 'stub/stub_audio_backend.dart' as stub;
import 'windows/win32_audio_backend.dart' as win32;

export 'audio_platform.dart';

/// Provides the correct [AudioPlayer], [AudioRecorder], and [AudioDevices]
/// implementations for the current platform.
///
/// Access via [AudioPlatform.instance]. Use [AudioPlatform.override] to inject
/// a custom backend (e.g., for testing).
class AudioPlatform {
  final AudioPlayerFactory createPlayer;
  final AudioRecorderFactory createRecorder;
  final AudioDevices devices;

  AudioPlatform({
    required this.createPlayer,
    required this.createRecorder,
    required this.devices,
  });

  static AudioPlatform? _instance;

  /// The platform singleton. Auto-detects on first access.
  static AudioPlatform get instance {
    _instance ??= _detect();
    return _instance!;
  }

  /// Override the platform backend (useful for testing or custom backends).
  static void override({
    required AudioPlayerFactory createPlayer,
    required AudioRecorderFactory createRecorder,
    required AudioDevices devices,
  }) {
    _instance = AudioPlatform(
      createPlayer: createPlayer,
      createRecorder: createRecorder,
      devices: devices,
    );
  }

  /// Reset to auto-detection.
  static void reset() {
    _instance = null;
  }

  static AudioPlatform _detect() {
    if (Platform.isWindows) {
      return AudioPlatform(
        createPlayer: win32.win32CreatePlayer,
        createRecorder: win32.win32CreateRecorder,
        devices: win32.win32Devices,
      );
    }
    // Future: Platform.isMacOS → CoreAudio, Platform.isLinux → ALSA, etc.
    return AudioPlatform(
      createPlayer: stub.stubCreatePlayer,
      createRecorder: stub.stubCreateRecorder,
      devices: stub.stubDevices,
    );
  }
}
