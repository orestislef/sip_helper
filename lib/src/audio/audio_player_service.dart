import 'dart:typed_data';
import '../logging.dart';
import '../codec/pcma_decoder.dart';
import '../platform/audio_platform.dart';
import 'sound_service.dart';

/// Real-time audio playback service for VoIP calls.
///
/// Routes decoded voice audio through SoundService's voice player,
/// which uses the same WinAudioPlayer pattern proven to work for DTMF/ringback.
class AudioPlayerService {
  static final AudioPlayerService instance = AudioPlayerService._internal();
  AudioPlayerService._internal();

  bool _isReady = false;
  int _outputDeviceId = defaultAudioDeviceId;
  int _packetCount = 0;
  int _dropCount = 0;

  void setOutputDevice(int deviceId) {
    if (_outputDeviceId == deviceId) return;
    _outputDeviceId = deviceId;
    sipLog('[AudioPlayer] Output device set to $deviceId');
  }

  Future<void> initialize() async {
    if (_isReady) return;
    _packetCount = 0;
    _dropCount = 0;
    _isReady = true;
    sipLog('[AudioPlayer] Ready (routing through SoundService voice player)');
  }

  /// Decode PCMA payload, upsample 8k→16k, and play through SoundService.
  void processAudioPacket(Uint8List pcmaPayload) {
    if (!_isReady) return;

    // Start voice player on first packet
    if (!SoundService.instance.isVoicePlaying) {
      SoundService.instance.startVoicePlayback();
      if (!SoundService.instance.isVoicePlaying) {
        _dropCount++;
        if (_dropCount <= 3) {
          sipLog('[AudioPlayer] Voice player failed to start');
        }
        return;
      }
    }

    _packetCount++;

    // Decode PCMA → PCM16 at 8kHz
    final pcm8k = PcmaDecoder.decode(pcmaPayload);

    // Upsample 8kHz → 16kHz (duplicate each sample)
    final pcm16k = _upsample2x(pcm8k);

    SoundService.instance.writeVoiceAudio(pcm16k);

    if (_packetCount <= 3 || _packetCount % 500 == 0) {
      sipLog(
          '[AudioPlayer] Packet #$_packetCount, ${pcmaPayload.length} PCMA → ${pcm16k.length} PCM16@16k via SoundService');
    }
  }

  /// Simple 2x upsample: duplicate each 16-bit sample.
  static Uint8List _upsample2x(Uint8List pcm8k) {
    final len = pcm8k.length;
    final pcm16k = Uint8List(len * 2);
    for (int i = 0; i < len; i += 2) {
      final lo = pcm8k[i];
      final hi = pcm8k[i + 1];
      final j = i * 2;
      pcm16k[j] = lo;
      pcm16k[j + 1] = hi;
      pcm16k[j + 2] = lo;
      pcm16k[j + 3] = hi;
    }
    return pcm16k;
  }

  void stop() {
    sipLog(
        '[AudioPlayer] Stopping. Processed $_packetCount packets, $_dropCount drops');
    SoundService.instance.stopVoicePlayback();
    _isReady = false;
    _packetCount = 0;
    _dropCount = 0;
  }

  void clear() {}

  void close() {
    stop();
  }
}
