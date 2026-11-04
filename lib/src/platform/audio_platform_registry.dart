import 'dart:io' show Platform;

import 'audio_platform.dart';
import 'mobile/method_channel_audio_backend.dart' as mobile;
import 'stub/stub_audio_backend.dart' as stub;
import 'windows/win32_audio_backend.dart' as win32;

export 'audio_platform.dart';

/// Provides the [AudioPlayer], [AudioRecorder], [AudioDevices] and
/// [AudioSession] implementations for the current platform.
///
/// Access via [AudioPlatform.instance]. Use [AudioPlatform.override] to inject
/// a custom backend (for example in tests).
class AudioPlatform {
  final AudioPlayerFactory createPlayer;
  final AudioRecorderFactory createRecorder;
  final AudioDevices devices;
  final AudioSession session;

  AudioPlatform({
    required this.createPlayer,
    required this.createRecorder,
    required this.devices,
    AudioSession? session,
  }) : session = session ?? NoopAudioSession();

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
    AudioSession? session,
  }) {
    _instance = AudioPlatform(
      createPlayer: createPlayer,
      createRecorder: createRecorder,
      devices: devices,
      session: session,
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
    if (Platform.isAndroid || Platform.isIOS) {
      return AudioPlatform(
        createPlayer: mobile.channelCreatePlayer,
        createRecorder: mobile.channelCreateRecorder,
        devices: mobile.channelDevices,
        session: mobile.channelSession,
      );
    }
    return AudioPlatform(
      createPlayer: stub.stubCreatePlayer,
      createRecorder: stub.stubCreateRecorder,
      devices: stub.stubDevices,
    );
  }
}
