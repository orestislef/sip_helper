import 'dart:typed_data';

import '../../logging.dart';
import '../audio_platform.dart';

/// Stub [AudioPlayerFactory] for unsupported platforms.
AudioPlayer stubCreatePlayer({
  int numBuffers = 16,
  int bufferSize = 320,
  int sampleRate = 8000,
  int deviceId = defaultAudioDeviceId,
}) =>
    StubAudioPlayer();

/// Stub [AudioRecorderFactory] for unsupported platforms.
AudioRecorder stubCreateRecorder({int deviceId = defaultAudioDeviceId}) =>
    StubAudioRecorder();

/// Stub [AudioDevices] for unsupported platforms.
final AudioDevices stubDevices = StubAudioDevices();

class StubAudioPlayer implements AudioPlayer {
  @override
  bool get isPlayerOpen => false;
  @override
  int get freeBufferCount => 0;

  @override
  bool open() {
    sipLog('[StubAudio] AudioPlayer.open() — not implemented on this platform');
    return false;
  }

  @override
  void write(Uint8List pcm16Data) {}
  @override
  bool writeWithStatus(Uint8List pcm16Data) => false;
  @override
  void reset() {}
  @override
  void close() {}
  @override
  int getVolume() => 0;
  @override
  void setMaxVolume() {}
}

class StubAudioRecorder implements AudioRecorder {
  @override
  void Function(Uint8List pcm16Data)? onData;

  @override
  bool open() {
    sipLog(
        '[StubAudio] AudioRecorder.open() — not implemented on this platform');
    return false;
  }

  @override
  void close() {}
}

class StubAudioDevices implements AudioDevices {
  @override
  List<String> getOutputDevices() => [];
  @override
  List<String> getInputDevices() => [];
}
