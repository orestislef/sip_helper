import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:sip_helper/src/codec/pcma_encoder.dart';
import 'package:sip_helper/src/codec/pcma_decoder.dart';

void main() {
  group('PCMA Codec', () {
    test('encode produces half the bytes of input', () {
      final pcm = Uint8List(320); // 160 samples * 2 bytes
      final encoded = PcmaEncoder.encode(pcm);
      expect(encoded.length, 160);
    });

    test('decode produces double the bytes of input', () {
      final alaw = Uint8List(160);
      final decoded = PcmaDecoder.decode(alaw);
      expect(decoded.length, 320);
    });

    test('encode throws on odd-length input', () {
      final odd = Uint8List(3);
      expect(() => PcmaEncoder.encode(odd), throwsA(isA<ArgumentError>()));
    });

    test('roundtrip preserves signal shape', () {
      final numSamples = 160;
      final pcm = Uint8List(numSamples * 2);
      final bd = ByteData.sublistView(pcm);
      for (int i = 0; i < numSamples; i++) {
        // Sawtooth pattern: -16000 to +15200
        final value = ((i % 40) - 20) * 800;
        bd.setInt16(i * 2, value.clamp(-32768, 32767), Endian.little);
      }

      final encoded = PcmaEncoder.encode(pcm);
      final decoded = PcmaDecoder.decode(encoded);

      expect(decoded.length, pcm.length);

      // Check that non-zero samples survive roundtrip
      final decBd = ByteData.sublistView(decoded);
      int nonZeroDec = 0;
      for (int i = 0; i < numSamples; i++) {
        final dec = decBd.getInt16(i * 2, Endian.little);
        if (dec.abs() > 0) nonZeroDec++;
      }
      expect(nonZeroDec, greaterThan(numSamples ~/ 2));
    });

    test('silence encodes and decodes to near-zero', () {
      final silence = Uint8List(320); // all zeros
      final encoded = PcmaEncoder.encode(silence);
      final decoded = PcmaDecoder.decode(encoded);

      final bd = ByteData.sublistView(decoded);
      for (int i = 0; i < 160; i++) {
        final sample = bd.getInt16(i * 2, Endian.little).abs();
        expect(sample, lessThan(100));
      }
    });
  });
}
