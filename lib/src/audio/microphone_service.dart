import 'dart:typed_data';

import '../codec/pcma_encoder.dart';
import '../codec/pcmu_encoder.dart';
import '../logging.dart';
import '../platform/audio_platform_registry.dart';

/// Microphone capture for calls.
///
/// Captures 8 kHz PCM16 from the platform recorder, cuts it into 20 ms
/// frames, encodes each frame with the call's codec and hands it to
/// [onAudioCaptured].
class MicrophoneService {
  static final MicrophoneService instance = MicrophoneService._internal();
  MicrophoneService._internal();

  static const int _frameBytes = 320; // 20 ms at 8 kHz, 16-bit mono

  AudioRecorder? _recorder;
  bool _isRecording = false;
  bool _starting = false;
  int _inputDeviceId = defaultAudioDeviceId;
  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// Payload type frames are encoded for (8 = PCMA, 0 = PCMU).
  int payloadType = 8;

  // Input gain (1.0 = normal).
  double _inputGain = 1.0;
  double get inputGain => _inputGain;
  void setInputGain(double gain) {
    _inputGain = gain.clamp(0.0, 20.0);
  }

  /// Mute. Capture keeps running and silence is sent instead, so the RTP
  /// stream stays continuous: the NAT pinhole stays open and the server's
  /// RTP timeout never fires. The SIP layer starts and stops capture on
  /// hold, resume and answer, which would undo a stop-based mute.
  bool _muted = false;
  bool get isMuted => _muted;
  void setMuted(bool muted) {
    _muted = muted;
    sipLog('[Microphone] ${muted ? 'Muted' : 'Unmuted'}');
  }

  /// Encoded 20 ms frames ready to send.
  void Function(Uint8List encoded, int payloadType)? onAudioCaptured;

  /// Raw PCM16 frames (after gain, before mute), for level meters.
  void Function(Uint8List pcm16Data)? onRawAudioCaptured;

  /// Select the input device. Restarts capture when running.
  void setInputDevice(int deviceId) {
    if (_inputDeviceId == deviceId) return;
    _inputDeviceId = deviceId;
    if (_isRecording) {
      stopCapture();
      startCapture();
    }
  }

  /// Start capturing. Returns false when the device could not be opened
  /// (no permission, no microphone, device busy).
  Future<bool> startCapture() async {
    if (_isRecording) return true;
    if (_starting) return true;
    _starting = true;
    try {
      final recorder =
          AudioPlatform.instance.createRecorder(deviceId: _inputDeviceId);
      recorder.onData = _onPcm;
      _pending.clear();
      final ok = await recorder.open();
      if (!ok) {
        sipLog('[Microphone] Failed to open recording device');
        return false;
      }
      if (!_starting) {
        // stopCapture() was called while the device was opening.
        recorder.close();
        return false;
      }
      _recorder = recorder;
      _isRecording = true;
      sipLog('[Microphone] Capture started');
      return true;
    } catch (e) {
      sipLog('[Microphone] Failed to start capture: $e');
      return false;
    } finally {
      _starting = false;
    }
  }

  void _onPcm(Uint8List pcm16Data) {
    if (!_isRecording) return;
    _pending.add(pcm16Data);
    if (_pending.length < _frameBytes) return;
    final all = _pending.takeBytes();
    var offset = 0;
    while (all.length - offset >= _frameBytes) {
      _processFrame(Uint8List.sublistView(all, offset, offset + _frameBytes));
      offset += _frameBytes;
    }
    if (offset < all.length) {
      _pending.add(Uint8List.fromList(all.sublist(offset)));
    }
  }

  void _processFrame(Uint8List frame) {
    var pcm = frame;
    if (_inputGain != 1.0) {
      pcm = Uint8List.fromList(frame);
      final bd = ByteData.sublistView(pcm);
      for (var i = 0; i + 1 < pcm.length; i += 2) {
        final s = bd.getInt16(i, Endian.little);
        bd.setInt16(
            i, (s * _inputGain).round().clamp(-32768, 32767), Endian.little);
      }
    }
    onRawAudioCaptured?.call(pcm);

    final pt = payloadType == 0 ? 0 : 8;
    final Uint8List encoded;
    if (_muted) {
      encoded = Uint8List(pcm.length ~/ 2)
        ..fillRange(0, pcm.length ~/ 2, pt == 0 ? PcmuEncoder.silence : 0xD5);
    } else {
      encoded = pt == 0 ? PcmuEncoder.encode(pcm) : PcmaEncoder.encode(pcm);
    }
    onAudioCaptured?.call(encoded, pt);
  }

  /// Stop capturing.
  Future<void> stopCapture() async {
    _starting = false;
    if (!_isRecording) return;
    _isRecording = false;
    _recorder?.close();
    _recorder = null;
    _pending.clear();
    sipLog('[Microphone] Capture stopped');
  }

  bool get isRecording => _isRecording;

  Future<void> dispose() async {
    await stopCapture();
  }
}
