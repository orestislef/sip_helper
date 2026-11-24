import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sip_helper/src/audio/microphone_service.dart';
import 'package:sip_helper/src/platform/audio_platform_registry.dart';
import 'package:sip_helper/src/platform/stub/stub_audio_backend.dart';

class _FakeRecorder implements AudioRecorder {
  static _FakeRecorder? last;
  static bool allow = true;
  bool closed = false;

  @override
  void Function(Uint8List pcm16Data)? onData;

  @override
  Future<bool> open() async {
    last = this;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return allow;
  }

  @override
  void close() => closed = true;
}

void main() {
  final mic = MicrophoneService.instance;
  late List<(Uint8List, int)> frames;

  setUp(() {
    AudioPlatform.override(
      createPlayer: stubCreatePlayer,
      createRecorder:
          ({int deviceId = defaultAudioDeviceId}) => _FakeRecorder(),
      devices: stubDevices,
    );
    _FakeRecorder.allow = true;
    frames = [];
    mic.onAudioCaptured = (data, pt) => frames.add((data, pt));
    mic.payloadType = 8;
    mic.setMuted(false);
  });

  tearDown(() async {
    await mic.stopCapture();
    AudioPlatform.reset();
  });

  test('cuts any chunk size into 20 ms frames', () async {
    expect(await mic.startCapture(), isTrue);
    final rec = _FakeRecorder.last!;
    rec.onData!(Uint8List(1000)); // 3 frames + 40 bytes
    rec.onData!(Uint8List(280)); // completes the 4th frame
    expect(frames, hasLength(4));
    expect(frames.every((f) => f.$1.length == 160 && f.$2 == 8), isTrue);
  });

  test(
    'encodes with the negotiated codec and mutes with codec silence',
    () async {
      mic.payloadType = 0;
      await mic.startCapture();
      final pcm = Uint8List(320);
      ByteData.sublistView(pcm).setInt16(0, 12000, Endian.little);
      _FakeRecorder.last!.onData!(pcm);
      expect(frames.last.$2, 0);
      expect(frames.last.$1.first, isNot(0xFF));

      mic.setMuted(true);
      _FakeRecorder.last!.onData!(pcm);
      expect(frames.last.$1, everyElement(0xFF));

      mic.payloadType = 8;
      _FakeRecorder.last!.onData!(pcm);
      expect(frames.last.$1, everyElement(0xD5));
    },
  );

  test('reports a recorder that cannot open (permission denied)', () async {
    _FakeRecorder.allow = false;
    expect(await mic.startCapture(), isFalse);
    expect(mic.isRecording, isFalse);
  });

  test('stop during an async open closes the recorder', () async {
    final start = mic.startCapture();
    await mic.stopCapture();
    expect(await start, isFalse);
    expect(_FakeRecorder.last!.closed, isTrue);
  });
}
