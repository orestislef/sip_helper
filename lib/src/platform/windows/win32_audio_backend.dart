import 'dart:typed_data';

import '../audio_platform.dart';
import 'win32_audio.dart';

/// WinMM WAVE_MAPPER constant — "use the system default device".
const int _waveMapper = 0xFFFFFFFF;

int _resolveDeviceId(int deviceId) =>
    deviceId == defaultAudioDeviceId ? _waveMapper : deviceId;

/// WinMM [AudioPlayerFactory].
AudioPlayer win32CreatePlayer({
  int numBuffers = 16,
  int bufferSize = 320,
  int sampleRate = 8000,
  int deviceId = defaultAudioDeviceId,
}) =>
    _Win32AudioPlayerAdapter(
      numBuffers: numBuffers,
      bufferSize: bufferSize,
      sampleRate: sampleRate,
      deviceId: _resolveDeviceId(deviceId),
    );

/// WinMM [AudioRecorderFactory].
AudioRecorder win32CreateRecorder({int deviceId = defaultAudioDeviceId}) =>
    _Win32AudioRecorderAdapter(deviceId: _resolveDeviceId(deviceId));

/// WinMM [AudioDevices].
final AudioDevices win32Devices = _Win32AudioDevicesAdapter();

class _Win32AudioPlayerAdapter implements AudioPlayer {
  final WinAudioPlayer _inner;

  _Win32AudioPlayerAdapter({
    int numBuffers = 16,
    int bufferSize = 320,
    int sampleRate = 8000,
    int deviceId = _waveMapper,
  }) : _inner = WinAudioPlayer(
          numBuffers: numBuffers,
          bufferSize: bufferSize,
          sampleRate: sampleRate,
          deviceId: deviceId,
        );

  @override
  bool get isPlayerOpen => _inner.isPlayerOpen;
  @override
  int get freeBufferCount => _inner.freeBufferCount;
  @override
  bool open() => _inner.open();
  @override
  void write(Uint8List pcm16Data) => _inner.write(pcm16Data);
  @override
  bool writeWithStatus(Uint8List pcm16Data) =>
      _inner.writeWithStatus(pcm16Data);
  @override
  void reset() => _inner.reset();
  @override
  void close() => _inner.close();
  @override
  int getVolume() => _inner.getVolume();
  @override
  void setMaxVolume() => _inner.setMaxVolume();
}

class _Win32AudioRecorderAdapter implements AudioRecorder {
  final WinAudioRecorder _inner;

  _Win32AudioRecorderAdapter({int deviceId = _waveMapper})
      : _inner = WinAudioRecorder(deviceId: deviceId);

  @override
  void Function(Uint8List pcm16Data)? get onData => _inner.onData;
  @override
  set onData(void Function(Uint8List pcm16Data)? callback) {
    _inner.onData = callback;
  }

  @override
  bool open() => _inner.open();
  @override
  void close() => _inner.close();
}

class _Win32AudioDevicesAdapter implements AudioDevices {
  @override
  List<String> getOutputDevices() => WinAudioDevices.getOutputDevices();
  @override
  List<String> getInputDevices() => WinAudioDevices.getInputDevices();
}
