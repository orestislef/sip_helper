import 'dart:typed_data';
import '../logging.dart';
import '../platform/windows/win32_audio.dart';
import '../codec/pcma_encoder.dart';

/// Microphone capture service for VoIP calls.
///
/// Uses Windows WinMM waveIn API for direct PCM capture from microphone.
/// Encodes PCM16 -> PCMA and delivers via callbacks. No Flutter plugin dependencies.
class MicrophoneService {
  static final MicrophoneService instance = MicrophoneService._internal();
  MicrophoneService._internal();

  WinAudioRecorder? _recorder;
  bool _isRecording = false;
  int _inputDeviceId = 0xFFFFFFFF; // WAVE_MAPPER (system default)

  // Input gain (1.0 = normal, up to 10.0 = 1000%)
  double _inputGain = 1.0;
  double get inputGain => _inputGain;
  void setInputGain(double gain) {
    _inputGain = gain.clamp(0.0, 20.0);
  }

  // Audio callbacks (decoupled from concrete implementations)
  void Function(Uint8List pcmaData, int payloadType)? onAudioCaptured;
  void Function(Uint8List pcm16Data)? onRawAudioCaptured;

  /// Set the input device ID. If already recording, restarts on the new device.
  void setInputDevice(int deviceId) {
    if (_inputDeviceId == deviceId) return;
    _inputDeviceId = deviceId;
    if (_isRecording) {
      _recorder?.close();
      _recorder = WinAudioRecorder(deviceId: _inputDeviceId);
      _recorder!.onData = _processAudioData;
      if (!_recorder!.open()) {
        _isRecording = false;
        sipLog('[Microphone] Failed to switch to device $deviceId');
      } else {
        sipLog('[Microphone] Switched to device $deviceId');
      }
    }
  }

  /// Start capturing audio from the microphone and sending via RTP.
  Future<void> startCapture() async {
    if (_isRecording) return;

    _recorder = WinAudioRecorder(deviceId: _inputDeviceId);
    _recorder!.onData = _processAudioData;

    if (_recorder!.open()) {
      _isRecording = true;
      sipLog('[Microphone] Capture started via WinMM');
    } else {
      sipLog('[Microphone] Failed to open WinMM recording device');
    }
  }

  /// Process captured PCM16 data — encode to PCMA and deliver via callbacks.
  void _processAudioData(Uint8List pcm16Data) {
    if (!_isRecording) return;

    // Apply input gain
    if (_inputGain != 1.0) {
      final bd = ByteData.sublistView(pcm16Data);
      for (int i = 0; i < pcm16Data.length - 1; i += 2) {
        final sample = bd.getInt16(i, Endian.little);
        final amplified = (sample * _inputGain).round().clamp(-32768, 32767);
        bd.setInt16(i, amplified, Endian.little);
      }
    }

    onRawAudioCaptured?.call(pcm16Data);
    final pcmaData = PcmaEncoder.encode(pcm16Data);
    onAudioCaptured?.call(pcmaData, 8);
  }

  /// Stop capturing.
  Future<void> stopCapture() async {
    if (!_isRecording) return;
    _isRecording = false;
    _recorder?.close();
    _recorder = null;
    sipLog('[Microphone] Capture stopped');
  }

  bool get isRecording => _isRecording;

  Future<void> dispose() async {
    await stopCapture();
  }
}
