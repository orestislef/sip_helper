import 'dart:typed_data';
import '../codec/pcma_decoder.dart';

/// Tracks real-time audio levels from mic input and speaker output.
/// Provides normalized 0.0-1.0 levels for UI visualization.
class AudioLevelService {
  static final AudioLevelService instance = AudioLevelService._internal();
  AudioLevelService._internal();

  double _inputLevel = 0.0;
  double _outputLevel = 0.0;

  double get inputLevel => _inputLevel;
  double get outputLevel => _outputLevel;

  /// Feed raw PCM16 microphone data to compute input level.
  void updateInputFromPcm16(Uint8List pcm16Data) {
    _inputLevel = _computeLevelPcm16(pcm16Data);
  }

  /// Feed raw PCMA (G.711 A-law) RTP payload to compute output level.
  void updateOutputFromPcma(Uint8List pcmaData) {
    // Decode PCMA to PCM16 first, then compute level
    final pcm16 = PcmaDecoder.decode(pcmaData);
    _outputLevel = _computeLevelPcm16(pcm16);
  }

  /// Compute RMS level from PCM16 data, normalized to 0.0-1.0.
  double _computeLevelPcm16(Uint8List pcm16Data) {
    if (pcm16Data.length < 2) return 0.0;

    final bd = ByteData.sublistView(pcm16Data);
    final numSamples = pcm16Data.length ~/ 2;

    double peak = 0.0;
    for (int i = 0; i < numSamples; i++) {
      final sample = bd.getInt16(i * 2, Endian.little).abs().toDouble();
      if (sample > peak) peak = sample;
    }

    final level = peak / 32768.0;
    return level.clamp(0.0, 1.0);
  }

  void reset() {
    _inputLevel = 0.0;
    _outputLevel = 0.0;
  }
}
