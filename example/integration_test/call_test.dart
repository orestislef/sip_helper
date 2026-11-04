// On-device test of the full stack: SIP signalling against an in-process
// server on loopback, real RTP sockets and the native audio plugin
// (microphone capture, playback, call session).
//
// Run with the microphone permission granted, for example:
//   flutter build apk --debug && adb install -r -g build/app/outputs/flutter-apk/app-debug.apk
//   flutter test integration_test/call_test.dart -d <device>
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sip_helper/sip_helper.dart';

/// Minimal scripted SIP server.
class _Pbx {
  final RawDatagramSocket sip;
  final RawDatagramSocket rtp;
  InternetAddress? client;
  int? clientPort;
  final List<String> _inbox = [];
  final List<(bool Function(String), Completer<String>)> _waiters = [];
  final List<Uint8List> rtpIn = [];
  final List<Uint8List> _out = [];

  _Pbx(this.sip, this.rtp) {
    sip.listen((e) {
      if (e == RawSocketEvent.write) _flush();
      if (e != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = sip.receive()) != null) {
        client = d!.address;
        clientPort = d.port;
        final text = utf8.decode(d.data).replaceAll('\r', '');
        if (text.trim().isEmpty) continue;
        final w = _waiters.where((w) => w.$1(text)).firstOrNull;
        if (w != null) {
          _waiters.remove(w);
          w.$2.complete(text);
        } else {
          _inbox.add(text);
        }
      }
    });
    rtp.listen((e) {
      if (e != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = rtp.receive()) != null) {
        rtpIn.add(d!.data);
      }
    });
  }

  static Future<_Pbx> start() async => _Pbx(
      await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
      await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0));

  Future<String> next(String startsWith,
      {Duration timeout = const Duration(seconds: 10)}) {
    bool test(String m) => m.startsWith(startsWith);
    final i = _inbox.indexWhere(test);
    if (i != -1) return Future.value(_inbox.removeAt(i));
    final c = Completer<String>();
    _waiters.add((test, c));
    return c.future.timeout(timeout);
  }

  void send(String msg) {
    _out.add(utf8.encode(msg));
    _flush();
  }

  void _flush() {
    while (_out.isNotEmpty) {
      if (sip.send(_out.first, client!, clientPort!) == 0) {
        sip.writeEventsEnabled = true;
        return;
      }
      _out.removeAt(0);
    }
  }

  static String header(String msg, String name) {
    for (final line in msg.split('\n')) {
      if (line.toLowerCase().startsWith('${name.toLowerCase()}:')) {
        return line.substring(name.length + 1).trim();
      }
    }
    return '';
  }

  static String body(String msg) {
    final i = msg.indexOf('\n\n');
    return i == -1 ? '' : msg.substring(i + 2);
  }

  String respond(String req, int code, String reason,
      {String? toTag, List<String> extra = const [], String? sdp}) {
    final b = StringBuffer('SIP/2.0 $code $reason\r\n');
    for (final line in req.split('\n')) {
      if (line.toLowerCase().startsWith('via:')) b.write('$line\r\n');
    }
    b.write('From: ${header(req, 'From')}\r\n');
    final to = header(req, 'To');
    b.write(toTag != null && !to.contains('tag=')
        ? 'To: $to;tag=$toTag\r\n'
        : 'To: $to\r\n');
    b.write('Call-ID: ${header(req, 'Call-ID')}\r\n');
    b.write('CSeq: ${header(req, 'CSeq')}\r\n');
    for (final h in extra) {
      b.write('$h\r\n');
    }
    _finish(b, sdp);
    return b.toString();
  }

  String sdp({String direction = 'sendrecv'}) => [
        'v=0',
        'o=- 1 1 IN IP4 127.0.0.1',
        's=test',
        'c=IN IP4 127.0.0.1',
        't=0 0',
        'm=audio ${rtp.port} RTP/AVP 8 101',
        'a=rtpmap:8 PCMA/8000',
        'a=rtpmap:101 telephone-event/8000',
        'a=$direction',
        '',
      ].join('\r\n');

  void _finish(StringBuffer b, String? sdp) {
    if (sdp == null) {
      b.write('Content-Length: 0\r\n\r\n');
    } else {
      b.write('Content-Type: application/sdp\r\n');
      b.write('Content-Length: ${utf8.encode(sdp).length}\r\n\r\n$sdp');
    }
  }

  /// Send [seconds] of a 1 kHz A-law tone to [host]:[port].
  Future<void> sendTone(String host, int port, double seconds) async {
    final addr = InternetAddress(host);
    var seq = 0;
    var ts = 0;
    final packets = (seconds * 50).round();
    for (var p = 0; p < packets; p++) {
      final pcm = Uint8List(320);
      final bd = ByteData.sublistView(pcm);
      for (var i = 0; i < 160; i++) {
        final t = (p * 160 + i) / 8000;
        bd.setInt16(i * 2, (12000 * sin(2 * pi * 1000 * t)).round(), Endian.little);
      }
      final payload = PcmaEncoder.encode(pcm);
      final pkt = Uint8List(12 + payload.length)
        ..[0] = 0x80
        ..[1] = 8
        ..[2] = seq >> 8
        ..[3] = seq & 0xFF
        ..[4] = (ts >> 24) & 0xFF
        ..[5] = (ts >> 16) & 0xFF
        ..[6] = (ts >> 8) & 0xFF
        ..[7] = ts & 0xFF
        ..[8] = 9
        ..[9] = 9
        ..[10] = 9
        ..[11] = 9;
      pkt.setRange(12, pkt.length, payload);
      rtp.send(pkt, addr, port);
      seq++;
      ts += 160;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void close() {
    sip.close();
    rtp.close();
  }
}

Future<void> _eventually(bool Function() test,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

(String, int) _sdpEndpoint(String sdp) {
  final host = RegExp(r'c=IN IP4 (\S+)').firstMatch(sdp)!.group(1)!;
  final port = int.parse(RegExp(r'm=audio (\d+)').firstMatch(sdp)!.group(1)!);
  return (host, port);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('register, outgoing and incoming call with native audio',
      (tester) async {
    final log = <String>[];
    sipLogger = (m) {
      log.add(m);
      // ignore: avoid_print
      print(m);
    };
    final pbx = await _Pbx.start();
    final sip = SipHelper.instance;
    final events = <String>[];
    final errors = <String>[];
    final subs = [
      sip.callEventStream.listen((e) => events.add(e.event.name)),
      sip.errorStream.listen(errors.add),
    ];

    try {
      expect(await sip.requestMicrophonePermission(), isTrue,
          reason: 'grant RECORD_AUDIO before running (adb install -g)');

      await sip.initialize(SipConfiguration(
        server: '127.0.0.1',
        port: pbx.sip.port,
        username: '1001',
        password: 'secret',
        keepAliveInterval: 0,
      ));
      await sip.connect();

      // REGISTER with a digest challenge.
      final reg1 = await pbx.next('REGISTER');
      pbx.send(pbx.respond(reg1, 401, 'Unauthorized',
          extra: ['WWW-Authenticate: Digest realm="test", nonce="n1"']));
      final reg2 = await pbx.next('REGISTER');
      expect(_Pbx.header(reg2, 'Authorization'), contains('response='));
      pbx.send(pbx.respond(reg2, 200, 'OK', toTag: 'r'));
      await _eventually(() => sip.isConnected);

      // ── Outgoing call ──
      final callId = await sip.makeCall('2000');
      final invite = await pbx.next('INVITE');
      final (_, phonePort) = _sdpEndpoint(_Pbx.body(invite));
      pbx.send(pbx.respond(invite, 180, 'Ringing', toTag: 'b'));
      await _eventually(() => events.contains('ringing'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      pbx.send(pbx.respond(invite, 200, 'OK', toTag: 'b', extra: [
        'Contact: <sip:2000@127.0.0.1:${pbx.sip.port}>',
      ], sdp: pbx.sdp()));
      await pbx.next('ACK');
      await _eventually(() => events.contains('confirmed'));

      // Microphone audio reaches the server as 20 ms PCMA packets.
      pbx.rtpIn.clear();
      await Future<void>.delayed(const Duration(seconds: 3));
      final audio = pbx.rtpIn.where((p) => (p[1] & 0x7F) == 8).toList();
      expect(audio.length, greaterThan(100), reason: 'mic RTP packets in 3 s');
      expect(audio.every((p) => p.length == 172), isTrue);
      final distinct = <int>{};
      for (final p in audio) {
        distinct.addAll(p.sublist(12));
      }
      expect(distinct.length, greaterThan(4),
          reason: 'microphone delivers real samples, not constant silence');

      // Remote audio is decoded and played.
      await pbx.sendTone('127.0.0.1', phonePort, 2);
      expect(sip.audioLevelService.outputLevel, greaterThan(0.1));

      // DTMF as RFC 4733.
      pbx.rtpIn.clear();
      await sip.sendDtmf(callId, '5');
      final dtmf = pbx.rtpIn.where((p) => (p[1] & 0x7F) == 101).toList();
      expect(dtmf, isNotEmpty);
      expect(dtmf.first[12], 5);

      // Speaker and mute do not break the stream.
      await sip.setSpeakerphone(true);
      sip.setMuted(true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sip.setMuted(false);
      await sip.setSpeakerphone(false);

      // Hold stops the microphone, resume brings it back.
      final hold = sip.holdCall(callId);
      final reinv = await pbx.next('INVITE');
      expect(_Pbx.body(reinv), contains('a=sendonly'));
      pbx.send(pbx.respond(reinv, 200, 'OK', sdp: pbx.sdp(direction: 'recvonly')));
      await pbx.next('ACK');
      expect(await hold, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      pbx.rtpIn.clear();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(pbx.rtpIn.where((p) => (p[1] & 0x7F) == 8).length, lessThan(5));

      final resume = sip.unholdCall(callId);
      final reinv2 = await pbx.next('INVITE');
      pbx.send(pbx.respond(reinv2, 200, 'OK', sdp: pbx.sdp()));
      await pbx.next('ACK');
      expect(await resume, isTrue);
      pbx.rtpIn.clear();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(pbx.rtpIn.where((p) => (p[1] & 0x7F) == 8).length, greaterThan(30));

      await sip.hangupCall(callId);
      final bye = await pbx.next('BYE');
      pbx.send(pbx.respond(bye, 200, 'OK'));
      await _eventually(() => events.contains('ended'));

      // ── Incoming call ──
      events.clear();
      final incoming = Completer<CallInfo>();
      final sub = sip.incomingCallStream.listen(incoming.complete);
      final inSdp = pbx.sdp();
      final inv = 'INVITE sip:1001@127.0.0.1:${pbx.clientPort} SIP/2.0\r\n'
          'Via: SIP/2.0/UDP 127.0.0.1:${pbx.sip.port};branch=z9hG4bKin1;rport\r\n'
          'From: "Front Desk" <sip:3000@127.0.0.1>;tag=in1\r\n'
          'To: <sip:1001@127.0.0.1>\r\n'
          'Call-ID: incoming-1\r\n'
          'CSeq: 1 INVITE\r\n'
          'Contact: <sip:3000@127.0.0.1:${pbx.sip.port}>\r\n'
          'Content-Type: application/sdp\r\n'
          'Content-Length: ${utf8.encode(inSdp).length}\r\n\r\n$inSdp';
      pbx.send(inv);
      await pbx.next('SIP/2.0 180');
      final call = await incoming.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      expect(call.callerName, 'Front Desk');
      await Future<void>.delayed(const Duration(seconds: 1)); // ring tone plays
      await sip.answerCall('incoming-1');
      final ok = await pbx.next('SIP/2.0 200');
      final (_, inPort) = _sdpEndpoint(_Pbx.body(ok));
      final toTag = RegExp(r'tag=([^;\s>]+)').firstMatch(_Pbx.header(ok, 'To'))!.group(1)!;
      pbx.send('ACK sip:1001@127.0.0.1:${pbx.clientPort} SIP/2.0\r\n'
          'Via: SIP/2.0/UDP 127.0.0.1:${pbx.sip.port};branch=z9hG4bKack1;rport\r\n'
          'From: "Front Desk" <sip:3000@127.0.0.1>;tag=in1\r\n'
          'To: <sip:1001@127.0.0.1>;tag=$toTag\r\n'
          'Call-ID: incoming-1\r\n'
          'CSeq: 1 ACK\r\n'
          'Content-Length: 0\r\n\r\n');
      await _eventually(() => events.contains('confirmed'));
      pbx.rtpIn.clear();
      await pbx.sendTone('127.0.0.1', inPort, 1);
      expect(pbx.rtpIn.where((p) => (p[1] & 0x7F) == 8).length, greaterThan(30));

      pbx.send('BYE sip:1001@127.0.0.1:${pbx.clientPort} SIP/2.0\r\n'
          'Via: SIP/2.0/UDP 127.0.0.1:${pbx.sip.port};branch=z9hG4bKbye1;rport\r\n'
          'From: "Front Desk" <sip:3000@127.0.0.1>;tag=in1\r\n'
          'To: <sip:1001@127.0.0.1>;tag=$toTag\r\n'
          'Call-ID: incoming-1\r\n'
          'CSeq: 2 BYE\r\n'
          'Content-Length: 0\r\n\r\n');
      await pbx.next('SIP/2.0 200');
      await _eventually(() => events.contains('ended'));

      // Clean shutdown.
      final unreg = sip.disconnect();
      final reg3 = await pbx.next('REGISTER');
      expect(_Pbx.header(reg3, 'Expires'), '0');
      pbx.send(pbx.respond(reg3, 200, 'OK'));
      await unreg;
      expect(errors.where((e) => !e.contains('permission')), isEmpty,
          reason: errors.join('\n'));
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      pbx.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
