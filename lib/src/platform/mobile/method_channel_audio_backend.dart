import 'dart:async';

import 'package:flutter/services.dart';

import '../../logging.dart';
import '../audio_platform.dart';

/// Audio backend for Android and iOS, talking to the native side of the
/// plugin over a method channel. Microphone frames arrive on an event
/// channel as 8 kHz mono PCM16.
const MethodChannel _channel = MethodChannel('sip_helper/audio');
const EventChannel _micChannel = EventChannel('sip_helper/audio/mic');

Future<T?> _invoke<T>(String method, [Object? args]) async {
  try {
    return await _channel.invokeMethod<T>(method, args);
  } on MissingPluginException {
    sipLog('[Audio] Native plugin missing for $method, rebuild the app '
        'after adding sip_helper');
    return null;
  } on PlatformException catch (e) {
    sipLog('[Audio] $method failed: ${e.code} ${e.message}');
    return null;
  }
}

/// [AudioPlayerFactory] for Android and iOS.
AudioPlayer channelCreatePlayer({
  int numBuffers = 16,
  int bufferSize = 320,
  int sampleRate = 8000,
  int deviceId = defaultAudioDeviceId,
}) =>
    _ChannelAudioPlayer(sampleRate);

/// [AudioRecorderFactory] for Android and iOS.
AudioRecorder channelCreateRecorder({int deviceId = defaultAudioDeviceId}) =>
    _ChannelAudioRecorder();

/// [AudioDevices] for Android and iOS. Routing is done with
/// [AudioSession.setSpeakerphone] and the system (Bluetooth, wired headset),
/// so no device list is exposed.
final AudioDevices channelDevices = _ChannelAudioDevices();

/// [AudioSession] for Android and iOS.
final AudioSession channelSession = _ChannelAudioSession();

class _ChannelAudioPlayer implements AudioPlayer {
  final int sampleRate;
  bool _open = false;

  _ChannelAudioPlayer(this.sampleRate);

  @override
  bool get isPlayerOpen => _open;

  @override
  int get freeBufferCount => _open ? 16 : 0;

  @override
  bool open() {
    // The native player opens lazily on the first write, so creating it at
    // start-up does not grab the audio session (and stop the user's music).
    _open = true;
    _invoke<bool>('openPlayer', {'sampleRate': sampleRate}).then((ok) {
      if (ok != true) {
        _open = false;
        sipLog('[Audio] Native player failed to open');
      }
    });
    return true;
  }

  @override
  void write(Uint8List pcm16Data) {
    if (!_open || pcm16Data.isEmpty) return;
    _invoke<void>('write', pcm16Data);
  }

  @override
  bool writeWithStatus(Uint8List pcm16Data) {
    write(pcm16Data);
    return _open;
  }

  @override
  void reset() {
    if (_open) _invoke<void>('resetPlayer');
  }

  @override
  void close() {
    if (!_open) return;
    _open = false;
    _invoke<void>('closePlayer');
  }

  @override
  int getVolume() => 0;

  @override
  void setMaxVolume() {}
}

class _ChannelAudioRecorder implements AudioRecorder {
  StreamSubscription<dynamic>? _sub;
  bool _closed = false;

  @override
  void Function(Uint8List pcm16Data)? onData;

  @override
  Future<bool> open() async {
    _closed = false;
    final ok = await _invoke<bool>('openRecorder', {'sampleRate': 8000});
    if (ok != true || _closed) {
      if (ok == true) _invoke<void>('closeRecorder');
      return false;
    }
    _sub = _micChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Uint8List) onData?.call(event);
      },
      onError: (Object e) => sipLog('[Audio] Microphone stream error: $e'),
    );
    return true;
  }

  @override
  void close() {
    _closed = true;
    _sub?.cancel();
    _sub = null;
    _invoke<void>('closeRecorder');
  }
}

class _ChannelAudioDevices implements AudioDevices {
  @override
  List<String> getOutputDevices() => const [];
  @override
  List<String> getInputDevices() => const [];
}

class _ChannelAudioSession implements AudioSession {
  bool _speaker = false;

  @override
  Future<bool> hasMicrophonePermission() async =>
      await _invoke<bool>('hasPermission') ?? false;

  @override
  Future<bool> requestMicrophonePermission() async =>
      await _invoke<bool>('requestPermission') ?? false;

  @override
  Future<void> activate() async {
    await _invoke<void>('startSession', {'speaker': _speaker});
  }

  @override
  Future<void> deactivate() async {
    _speaker = false;
    await _invoke<void>('stopSession');
  }

  @override
  Future<void> setSpeakerphone(bool on) async {
    _speaker = on;
    await _invoke<void>('setSpeaker', {'on': on});
  }

  @override
  bool get isSpeakerphoneOn => _speaker;
}
