import 'dart:typed_data';

/// PCMU (G.711 µ-law) encoder: 16-bit little-endian PCM to µ-law bytes.
///
/// The server may settle a call on µ-law (payload type 0), for example a
/// call coming from a trunk that only speaks µ-law.
class PcmuEncoder {
  PcmuEncoder._();

  static const int _bias = 0x84;
  static const int _clip = 32635;

  /// One µ-law byte of silence.
  static const int silence = 0xFF;

  static final Uint8List _table = _build();

  static Uint8List _build() {
    final t = Uint8List(65536);
    for (var i = 0; i < 65536; i++) {
      var pcm = i < 32768 ? i : i - 65536;
      final sign = pcm < 0 ? 0x80 : 0x00;
      if (pcm < 0) pcm = -pcm;
      if (pcm > _clip) pcm = _clip;
      pcm += _bias;
      var exponent = 7;
      for (var mask = 0x4000; (pcm & mask) == 0 && exponent > 0; mask >>= 1) {
        exponent--;
      }
      final mantissa = (pcm >> (exponent + 3)) & 0x0F;
      t[i] = ~(sign | (exponent << 4) | mantissa) & 0xFF;
    }
    return t;
  }

  /// Encode [pcmData] (2 bytes per sample, little-endian).
  static Uint8List encode(Uint8List pcmData) {
    if (pcmData.length % 2 != 0) {
      throw ArgumentError('PCM data length must be even (2 bytes per sample)');
    }
    final out = Uint8List(pcmData.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final sample = pcmData[i * 2] | (pcmData[i * 2 + 1] << 8);
      out[i] = _table[sample & 0xFFFF];
    }
    return out;
  }
}
