import 'dart:typed_data';

import '../codec/pcma_decoder.dart';
import '../codec/pcmu_decoder.dart';
import '../logging.dart';
import '../platform/audio_platform.dart';
import 'audio_level.dart';
import 'sound_service.dart';

/// Real-time playback of the remote voice.
///
/// Decodes G.711 (A-law or µ-law), upsamples 8 kHz to 16 kHz and plays it
/// through [SoundService]'s shared player.
class AudioPlayerService {
  static final AudioPlayerService instance = AudioPlayerService._internal();
  AudioPlayerService._internal();

  bool _isReady = false;
  int _outputDeviceId = defaultAudioDeviceId;
  int _packetCount = 0;
  int _dropCount = 0;
  int _lastSample = 0;

  void setOutputDevice(int deviceId) {
    if (_outputDeviceId == deviceId) return;
    _outputDeviceId = deviceId;
    SoundService.instance.setOutputDevice(deviceId);
  }

  Future<void> initialize() async {
    if (_isReady) return;
    _packetCount = 0;
    _dropCount = 0;
    _lastSample = 0;
    _isReady = true;
  }

  /// Decode and play one RTP payload. [payloadType] 8 = PCMA, 0 = PCMU.
  /// Anything else (telephone-event, comfort noise) is not voice and is
  /// ignored instead of being played as noise.
  void processAudioPacket(Uint8List payload, {int payloadType = 8}) {
    if (!_isReady) return;
    final Uint8List pcm8k;
    if (payloadType == 8) {
      pcm8k = PcmaDecoder.decode(payload);
    } else if (payloadType == 0) {
      pcm8k = PcmuDecoder.decode(payload);
    } else {
      return;
    }

    final sound = SoundService.instance;
    if (!sound.isVoicePlaying) {
      // Remote audio is here (answer or early media): local ringback stops.
      sound.stopRingback();
      sound.startVoicePlayback();
      if (!sound.isVoicePlaying) {
        _dropCount++;
        if (_dropCount <= 3) sipLog('[AudioPlayer] Voice player failed to start');
        return;
      }
    }

    _packetCount++;
    AudioLevelService.instance.updateOutputFromPcm16(pcm8k);
    sound.writeVoiceAudio(_upsample2x(pcm8k));

    if (_packetCount <= 3 || _packetCount % 500 == 0) {
      sipLog('[AudioPlayer] Packet #$_packetCount, ${payload.length} bytes '
          '(PT $payloadType)');
    }
  }

  /// 8 kHz to 16 kHz with linear interpolation. Plain sample doubling
  /// leaves an image of the voice band above 4 kHz that sounds metallic.
  Uint8List _upsample2x(Uint8List pcm8k) {
    final n = pcm8k.length ~/ 2;
    final src = ByteData.sublistView(pcm8k);
    final out = Uint8List(n * 4);
    final dst = ByteData.sublistView(out);
    var prev = _lastSample;
    for (var i = 0; i < n; i++) {
      final s = src.getInt16(i * 2, Endian.little);
      dst.setInt16(i * 4, (prev + s) ~/ 2, Endian.little);
      dst.setInt16(i * 4 + 2, s, Endian.little);
      prev = s;
    }
    _lastSample = prev;
    return out;
  }

  void stop() {
    if (_isReady) {
      sipLog('[AudioPlayer] Stopping. Played $_packetCount packets, '
          '$_dropCount drops');
    }
    SoundService.instance.stopVoicePlayback();
    _isReady = false;
    _packetCount = 0;
    _dropCount = 0;
    _lastSample = 0;
  }

  void clear() {}

  void close() {
    stop();
  }
}
