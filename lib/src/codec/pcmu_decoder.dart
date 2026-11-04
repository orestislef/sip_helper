import 'dart:typed_data';

/// PCMU (G.711 µ-law) decoder: µ-law bytes to 16-bit little-endian PCM.
class PcmuDecoder {
  PcmuDecoder._();

  static final Int16List _table = _build();

  static Int16List _build() {
    final table = Int16List(256);
    for (var i = 0; i < 256; i++) {
      final u = ~i & 0xFF;
      final sign = u & 0x80;
      final exponent = (u >> 4) & 0x07;
      final mantissa = u & 0x0F;
      var sample = (((mantissa << 3) + 0x84) << exponent) - 0x84;
      if (sign != 0) sample = -sample;
      table[i] = sample;
    }
    return table;
  }

  /// Decode [ulawData] (1 byte per sample).
  static Uint8List decode(Uint8List ulawData) {
    final pcm = Uint8List(ulawData.length * 2);
    final bd = ByteData.sublistView(pcm);
    for (var i = 0; i < ulawData.length; i++) {
      bd.setInt16(i * 2, _table[ulawData[i]], Endian.little);
    }
    return pcm;
  }
}
