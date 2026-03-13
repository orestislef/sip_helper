import 'dart:typed_data';

/// PCMA (G.711 A-law) decoder — ITU-T G.711 standard
/// Converts A-law compressed audio to 16-bit linear PCM
class PcmaDecoder {
  static final Int16List _alawTable = _generateAlawTable();

  /// Build the standard G.711 A-law → 16-bit PCM lookup table.
  ///
  /// Reference: ITU-T G.711 / Columbia g711.c `alaw2linear()`
  static Int16List _generateAlawTable() {
    final table = Int16List(256);

    for (int i = 0; i < 256; i++) {
      int val = i ^ 0x55; // Remove even-bit inversion

      int sign = val & 0x80; // bit 7: 1=positive, 0=negative
      int exponent = (val >> 4) & 0x07;
      int mantissa = val & 0x0F;

      int pcmVal;
      if (exponent == 0) {
        // Linear segment
        pcmVal = (mantissa << 4) + 8;
      } else if (exponent == 1) {
        pcmVal = (mantissa << 4) + 0x108;
      } else {
        pcmVal = ((mantissa << 4) + 0x108) << (exponent - 1);
      }

      // A-law sign convention: bit 1 = positive, bit 0 = negative
      table[i] = sign != 0 ? pcmVal : -pcmVal;
    }

    return table;
  }

  static Uint8List decode(Uint8List alawData) {
    final pcmData = Uint8List(alawData.length * 2);
    final bd = ByteData.sublistView(pcmData);

    for (int i = 0; i < alawData.length; i++) {
      bd.setInt16(i * 2, _alawTable[alawData[i]], Endian.little);
    }

    return pcmData;
  }
}
