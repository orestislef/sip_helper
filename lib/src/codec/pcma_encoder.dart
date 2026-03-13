import 'dart:typed_data';

/// PCMA (G.711 A-law) encoder
/// Converts 16-bit PCM to A-law compressed audio
class PcmaEncoder {
  static final List<int> _alawTable = _generateAlawTable();

  static List<int> _generateAlawTable() {
    final table = List<int>.filled(65536, 0);

    for (int i = 0; i < 65536; i++) {
      int pcm = i < 32768 ? i : i - 65536;

      int sign = (pcm < 0) ? 0x80 : 0x00;
      if (pcm < 0) pcm = -pcm;

      int exponent = 7;
      int expMask = 0x4000;
      while ((pcm & expMask) == 0 && exponent > 0) {
        exponent--;
        expMask >>= 1;
      }

      int mantissa = (pcm >> (exponent + (exponent > 0 ? 3 : 4))) & 0x0F;
      int alaw = sign | (exponent << 4) | mantissa;

      table[i] = alaw ^ 0x55;
    }

    return table;
  }

  static Uint8List encode(Uint8List pcmData) {
    if (pcmData.length % 2 != 0) {
      throw ArgumentError('PCM data length must be even (2 bytes per sample)');
    }

    final alawData = Uint8List(pcmData.length ~/ 2);

    for (int i = 0; i < alawData.length; i++) {
      final sample = (pcmData[i * 2]) | (pcmData[i * 2 + 1] << 8);
      final unsignedSample = sample & 0xFFFF;
      alawData[i] = _alawTable[unsignedSample];
    }

    return alawData;
  }
}
