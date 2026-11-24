import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sip_helper/src/codec/pcma_decoder.dart';
import 'package:sip_helper/src/codec/pcma_encoder.dart';
import 'package:sip_helper/src/codec/pcmu_decoder.dart';
import 'package:sip_helper/src/codec/pcmu_encoder.dart';

Uint8List _sine(int samples, double amplitude) {
  final pcm = Uint8List(samples * 2);
  final bd = ByteData.sublistView(pcm);
  for (var i = 0; i < samples; i++) {
    final v = (amplitude * sin(i * 2 * pi * 440 / 8000)).round();
    bd.setInt16(i * 2, v, Endian.little);
  }
  return pcm;
}

/// Signal to noise ratio in dB between [original] and [decoded].
double _snr(Uint8List original, Uint8List decoded) {
  final a = ByteData.sublistView(original);
  final b = ByteData.sublistView(decoded);
  var signal = 0.0;
  var noise = 0.0;
  for (var i = 0; i < original.length; i += 2) {
    final s = a.getInt16(i, Endian.little).toDouble();
    final d = b.getInt16(i, Endian.little).toDouble();
    signal += s * s;
    noise += (s - d) * (s - d);
  }
  return 10 * log(signal / max(noise, 1e-9)) / ln10;
}

void main() {
  group('PCMA codec', () {
    test('encode produces half the bytes of input', () {
      expect(PcmaEncoder.encode(Uint8List(320)).length, 160);
    });

    test('decode produces double the bytes of input', () {
      expect(PcmaDecoder.decode(Uint8List(160)).length, 320);
    });

    test('encode throws on odd-length input', () {
      expect(
        () => PcmaEncoder.encode(Uint8List(3)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('roundtrip keeps a voice-level tone clean', () {
      final pcm = _sine(800, 8000);
      final decoded = PcmaDecoder.decode(PcmaEncoder.encode(pcm));
      expect(_snr(pcm, decoded), greaterThan(30));
    });

    test('silence encodes to the A-law silence byte region', () {
      final decoded = PcmaDecoder.decode(PcmaEncoder.encode(Uint8List(320)));
      final bd = ByteData.sublistView(decoded);
      for (var i = 0; i < 160; i++) {
        expect(bd.getInt16(i * 2, Endian.little).abs(), lessThan(100));
      }
    });
  });

  group('PCMU codec', () {
    test('sizes', () {
      expect(PcmuEncoder.encode(Uint8List(320)).length, 160);
      expect(PcmuDecoder.decode(Uint8List(160)).length, 320);
    });

    test('silence byte is 0xFF and decodes to zero', () {
      final encoded = PcmuEncoder.encode(Uint8List(4));
      expect(encoded, everyElement(PcmuEncoder.silence));
      final decoded = PcmuDecoder.decode(Uint8List.fromList([0xFF, 0x7F]));
      final bd = ByteData.sublistView(decoded);
      expect(bd.getInt16(0, Endian.little), 0);
      expect(bd.getInt16(2, Endian.little), 0);
    });

    test('roundtrip keeps a voice-level tone clean', () {
      final pcm = _sine(800, 8000);
      final decoded = PcmuDecoder.decode(PcmuEncoder.encode(pcm));
      expect(_snr(pcm, decoded), greaterThan(30));
    });

    test('full scale values keep their sign', () {
      final pcm = Uint8List(4);
      final bd = ByteData.sublistView(pcm);
      bd.setInt16(0, 32767, Endian.little);
      bd.setInt16(2, -32768, Endian.little);
      final out = ByteData.sublistView(
        PcmuDecoder.decode(PcmuEncoder.encode(pcm)),
      );
      expect(out.getInt16(0, Endian.little), greaterThan(30000));
      expect(out.getInt16(2, Endian.little), lessThan(-30000));
    });
  });
}
