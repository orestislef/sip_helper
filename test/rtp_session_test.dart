import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sip_helper/src/net/datagram_sender.dart';
import 'package:sip_helper/src/rtp/rtp_session.dart';

import 'support/fake_pbx.dart' show eventually;

/// A socket that records received RTP packets.
class _Peer {
  final RawDatagramSocket socket;
  late final DatagramSender sender = DatagramSender(socket);
  final List<Uint8List> packets = [];

  _Peer(this.socket) {
    socket.listen((e) {
      if (e == RawSocketEvent.write) sender.onWrite();
      if (e != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = socket.receive()) != null) {
        packets.add(d!.data);
      }
    });
  }

  static Future<_Peer> start() async =>
      _Peer(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));

  void sendTo(int port, Uint8List data) =>
      sender.send(data, InternetAddress.loopbackIPv4, port);
}

Uint8List _rtp(int pt, int seq, List<int> payload) => Uint8List.fromList([
      0x80, pt, seq >> 8, seq & 0xFF, 0, 0, 0, 0, 1, 2, 3, 4, ...payload,
    ]);

int _seq(Uint8List p) => (p[2] << 8) | p[3];
int _ts(Uint8List p) => (p[4] << 24) | (p[5] << 16) | (p[6] << 8) | p[7];

void main() {
  final rtp = RtpSession.instance;
  late _Peer peer;
  late List<String> received;

  setUp(() async {
    peer = await _Peer.start();
    received = [];
    await rtp.initialize();
    rtp.onRtpPayload = (payload, pt) => received.add('$pt:${payload.length}');
    rtp.sendPayloadType = 8;
    rtp.dtmfPayloadType = 101;
    rtp.setRemoteEndpoint('127.0.0.1', peer.socket.port);
  });

  tearDown(() {
    rtp.close();
    rtp.onRtpPayload = null;
    peer.socket.close();
  });

  test('initialize is idempotent (the advertised port never changes)',
      () async {
    final port = rtp.localPort;
    await rtp.initialize();
    expect(rtp.localPort, port);
  });

  test('audio packets: header, marker on first, timestamps by samples',
      () async {
    rtp.sendAudio(Uint8List(160), 8);
    rtp.sendAudio(Uint8List(160), 8);
    rtp.sendAudio(Uint8List(80), 0);
    await eventually(() => peer.packets.length == 3);
    final p = peer.packets;
    expect(p[0][0], 0x80);
    expect(p[0][1], 0x80 | 8); // marker + PCMA
    expect(p[1][1], 8);
    expect(p[2][1], 0);
    expect(_seq(p[1]), (_seq(p[0]) + 1) & 0xFFFF);
    expect(_ts(p[1]) - _ts(p[0]), 160);
    expect(_ts(p[2]) - _ts(p[1]), 160);
    expect(p[0].length, 12 + 160);
  });

  test('silence matches the codec', () async {
    rtp.sendPayloadType = 0;
    rtp.sendSilence();
    await eventually(() => peer.packets.length == 1);
    expect(peer.packets.single.sublist(12), everyElement(0xFF));
  });

  test('RFC 4733 DTMF: same timestamp, growing duration, three end packets',
      () async {
    rtp.sendAudio(Uint8List(160), 8);
    await rtp.sendDtmf('#', durationMs: 60);
    rtp.sendAudio(Uint8List(160), 8);
    await eventually(() => peer.packets.length == 1 + 3 + 3 + 1);
    final events = peer.packets.where((p) => (p[1] & 0x7F) == 101).toList();
    expect(events, hasLength(6));
    final start = _ts(events.first);
    for (final e in events) {
      expect(_ts(e), start);
      expect(e[12], 11); // '#'
    }
    expect(events.first[1] & 0x80, 0x80); // marker on the first
    expect(events[1][1] & 0x80, 0);
    final durations = events.map((e) => (e[14] << 8) | e[15]).toList();
    expect(durations, [160, 320, 480, 480, 480, 480]);
    expect(events.take(3).every((e) => e[13] & 0x80 == 0), isTrue);
    expect(events.skip(3).every((e) => e[13] & 0x80 == 0x80), isTrue);
    final after = peer.packets.last;
    expect(after[1] & 0x7F, 8);
    expect(_ts(after), start + 480);
  });

  test('accepts the focused endpoint and drops other sources', () async {
    final stranger = await _Peer.start();
    peer.sendTo(rtp.localPort!, _rtp(8, 1, List.filled(160, 0xD5)));
    stranger.sendTo(rtp.localPort!, _rtp(8, 1, List.filled(160, 0xD5)));
    await eventually(() => received.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, ['8:160']);
    stranger.socket.close();
  });

  test('latches onto a steady new source when the announced one is silent',
      () async {
    final moved = await _Peer.start();
    await Future<void>.delayed(const Duration(milliseconds: 450));
    for (var i = 0; i < 10; i++) {
      moved.sendTo(rtp.localPort!, _rtp(0, i, List.filled(160, 0xFF)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await eventually(() => received.isNotEmpty);
    expect(rtp.remoteEndpoint, '127.0.0.1:${moved.socket.port}');
    expect(received.first, '0:160');
    moved.socket.close();
  });

  test('never latches onto another call\'s endpoint', () async {
    final held = await _Peer.start();
    rtp.otherLegEndpoints = {'127.0.0.1:${held.socket.port}'};
    await Future<void>.delayed(const Duration(milliseconds: 450));
    for (var i = 0; i < 12; i++) {
      held.sendTo(rtp.localPort!, _rtp(8, i, List.filled(160, 0xD5)));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, isEmpty);
    expect(rtp.remoteEndpoint, '127.0.0.1:${peer.socket.port}');
    held.socket.close();
  });
}
