import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sip_helper/src/logging.dart';
import 'package:sip_helper/src/sip/sip_call_event.dart';
import 'package:sip_helper/src/sip/sip_message.dart';
import 'package:sip_helper/src/sip/udp_sip_client.dart';

import 'support/fake_pbx.dart';

String _md5(String s) => md5.convert(utf8.encode(s)).toString();

Map<String, String> _params(String header) {
  final out = <String, String>{};
  for (final m in RegExp(r'(\w+)=(?:"([^"]*)"|([^,\s]+))').allMatches(header)) {
    out[m.group(1)!] = m.group(2) ?? m.group(3)!;
  }
  return out;
}

String _branch(SipMessage m) => headerParam(m.topVia!, 'branch')!;

void main() {
  late FakePbx pbx;
  late FakeMedia media;
  late UdpSipClient client;
  late List<String> events;
  late List<String> errors;
  late List<bool> registrations;
  late List<String> incoming;

  UdpSipClient makeClient({String password = 'secret'}) {
    final c = UdpSipClient(
      server: '127.0.0.1',
      port: pbx.port,
      username: '1001',
      password: password,
      displayName: 'Desk 1',
      media: media,
      localIp: '127.0.0.1',
      keepAliveInterval: Duration.zero,
    );
    c.onCallStateChanged = (id, e) => events.add('$id:${e.name}');
    c.onError = errors.add;
    c.onRegistrationStateChanged = registrations.add;
    c.onIncomingCall = (number, name, id) => incoming.add('$number|$name|$id');
    return c;
  }

  setUp(() async {
    if (Platform.environment['SIP_DEBUG'] != null) {
      sipLogger = (m) => print('${DateTime.now().toIso8601String().substring(17)} $m');
    }
    pbx = await FakePbx.start();
    media = FakeMedia();
    events = [];
    errors = [];
    registrations = [];
    incoming = [];
    client = makeClient();
  });

  tearDown(() async {
    await client.disconnect();
    pbx.close();
  });

  Future<void> register() async {
    await client.connect();
    final r1 = await pbx.request('REGISTER');
    expect(r1.header('Authorization'), isNull);
    pbx.send(pbx.respond(r1, 401, 'Unauthorized', toTag: 'reg', headers: [
      'WWW-Authenticate: Digest algorithm=MD5, realm="asterisk", '
          'nonce="abc123", qop="auth", opaque="op1"',
    ]));
    final r2 = await pbx.request('REGISTER');
    expect(r2.cseqNumber, r1.cseqNumber! + 1);
    expect(r2.callId, r1.callId);
    expect(extractTag(r2.from!), extractTag(r1.from!));
    final auth = _params(r2.header('Authorization')!);
    final uri = 'sip:127.0.0.1:${pbx.port}';
    expect(auth['uri'], uri);
    expect(auth['opaque'], 'op1');
    final ha1 = _md5('1001:asterisk:secret');
    final ha2 = _md5('REGISTER:$uri');
    expect(auth['response'],
        _md5('$ha1:abc123:${auth['nc']}:${auth['cnonce']}:auth:$ha2'));
    pbx.send(pbx.respond(r2, 200, 'OK', toTag: 'reg', headers: [
      'Contact: <sip:1001@127.0.0.1:${pbx.clientPort}>;expires=600',
    ]));
    await eventually(() => client.isRegistered);
    expect(registrations, [true]);
  }

  group('registration', () {
    test('digest auth with qop and opaque', () async {
      await register();
      final r = pbx.all.where((m) => m.method == 'REGISTER').last;
      expect(r.header('Expires'), '600');
      expect(r.header('Contact'), '<sip:1001@127.0.0.1:${pbx.clientPort}>');
      expect(r.topVia, contains(';rport'));
      expect(r.from, startsWith('"Desk 1" <sip:1001@127.0.0.1>'));
    });

    test('REGISTER is retransmitted when the server stays silent', () async {
      await client.connect();
      final first = await pbx.request('REGISTER');
      final again = await pbx.request('REGISTER',
          timeout: const Duration(seconds: 2));
      expect(_branch(again), _branch(first));
      expect(again.cseqNumber, first.cseqNumber);
    });

    test('wrong password is reported, not retried in a loop', () async {
      client = makeClient(password: 'wrong');
      await client.connect();
      final r1 = await pbx.request('REGISTER');
      pbx.send(pbx.respond(r1, 401, 'Unauthorized',
          headers: ['WWW-Authenticate: Digest realm="asterisk", nonce="n1"']));
      final r2 = await pbx.request('REGISTER');
      pbx.send(pbx.respond(r2, 401, 'Unauthorized',
          headers: ['WWW-Authenticate: Digest realm="asterisk", nonce="n2"']));
      await eventually(() => errors.isNotEmpty);
      expect(errors.single, contains('authentication rejected'));
      expect(client.isRegistered, isFalse);
      await pbx.expectNothing(
          (m) => m.method == 'REGISTER' && m.cseqNumber! > r2.cseqNumber!);
    });

    test('423 Interval Too Brief raises Expires to Min-Expires', () async {
      await client.connect();
      final r1 = await pbx.request('REGISTER');
      pbx.send(pbx.respond(r1, 423, 'Interval Too Brief',
          headers: ['Min-Expires: 1800']));
      final r2 = await pbx.request('REGISTER');
      expect(r2.header('Expires'), '1800');
    });

    test('unregister sends Expires 0 with the cached credentials', () async {
      await register();
      final done = client.unregister();
      final u = await pbx.request('REGISTER');
      expect(u.header('Expires'), '0');
      final auth = _params(u.header('Authorization')!);
      expect(auth['nonce'], 'abc123');
      expect(auth['nc'], '00000002');
      pbx.send(pbx.respond(u, 200, 'OK'));
      await done.timeout(const Duration(seconds: 2));
      expect(client.isRegistered, isFalse);
      expect(registrations, [true, false]);
    });

    test('answers OPTIONS and rejects unknown methods', () async {
      await register();
      pbx.send(pbx.requestTo('OPTIONS',
          callId: 'opt1', cseq: 1, from: '<sip:pbx@127.0.0.1>;tag=o', to: '<sip:1001@127.0.0.1>'));
      final ok = await pbx.response(200, method: 'OPTIONS');
      expect(ok.header('Allow'), contains('INVITE'));
      pbx.send(pbx.requestTo('MESSAGE',
          callId: 'msg1', cseq: 1, from: '<sip:pbx@127.0.0.1>;tag=m', to: '<sip:1001@127.0.0.1>',
          body: 'hi', contentType: 'text/plain'));
      await pbx.response(501, method: 'MESSAGE');
    });
  });

  group('incoming call', () {
    const callId = 'in-call-1';
    const remoteFrom = '"Alice Smith" <sip:2000@127.0.0.1>;tag=pbxtag';
    late String localTag;

    Future<SipMessage> sendInvite({String? sdp, int cseq = 102}) async {
      final invite = pbx.requestTo('INVITE',
          callId: callId,
          cseq: cseq,
          from: remoteFrom,
          to: '<sip:1001@127.0.0.1>',
          branch: 'z9hG4bKinv$cseq',
          headers: [
            'Record-Route: <sip:127.0.0.1:${pbx.port};lr>',
            'Via: SIP/2.0/UDP 10.9.9.9:5060;branch=z9hG4bKupstream',
          ],
          body: sdp);
      pbx.send(invite);
      return SipMessage.parse(invite)!;
    }

    String inDialog(String method, int cseq, {String? body, String? branch}) =>
        pbx.requestTo(method,
            callId: callId,
            cseq: cseq,
            from: remoteFrom,
            to: '<sip:1001@127.0.0.1>;tag=$localTag',
            branch: branch,
            body: body);

    Future<void> answered({String? sdp}) async {
      await register();
      await sendInvite(sdp: sdp ?? pbxSdp(payloads: '0 101'));
      await pbx.response(100);
      final ringing = await pbx.response(180);
      localTag = extractTag(ringing.to!)!;
      await eventually(() => incoming.isNotEmpty);
      await client.answerCall(callId);
      await pbx.response(200, method: 'INVITE');
      pbx.send(inDialog('ACK', 102));
      await eventually(() => events.contains('$callId:confirmed'));
      pbx.clearInbox();
    }

    test('rings once, answers with the offered codec, confirms on ACK',
        () async {
      await register();
      await sendInvite(sdp: pbxSdp(payloads: '0 101'));
      await pbx.response(100);
      final ringing = await pbx.response(180);
      localTag = extractTag(ringing.to!)!;
      expect(ringing.headerAll('Via'), hasLength(2));
      expect(ringing.header('Contact'), isNotNull);
      await eventually(() => incoming.isNotEmpty);
      expect(incoming.single, '2000|Alice Smith|$callId');

      // A retransmitted INVITE repeats 180 and does not ring twice.
      await sendInvite(sdp: pbxSdp(payloads: '0 101'));
      await pbx.response(180);
      expect(incoming, hasLength(1));

      await client.answerCall(callId);
      final ok = await pbx.response(200, method: 'INVITE');
      expect(extractTag(ok.to!), localTag);
      expect(ok.header('Record-Route'), '<sip:127.0.0.1:${pbx.port};lr>');
      expect(ok.body, contains('m=audio 40000 RTP/AVP 0 101'));
      expect(ok.body, isNot(contains('PCMA')));
      expect(media.remotes.last, '127.0.0.1:30000/0/101');
      expect(media.micStarts, 1);
      expect(media.silences, 1);

      // No ACK yet: the 200 OK is retransmitted.
      await pbx.response(200,
          method: 'INVITE', timeout: const Duration(seconds: 2));

      pbx.send(inDialog('ACK', 102));
      await eventually(() => events.contains('$callId:confirmed'));
      pbx.clearInbox();
      await pbx.expectNothing((m) => m.statusCode == 200,
          within: const Duration(milliseconds: 1500));
      expect(events.where((e) => e == '$callId:confirmed'), hasLength(1));
    });

    test('remote hold and resume', () async {
      await answered();
      final starts = media.micStarts;
      pbx.send(inDialog('INVITE', 103,
          body: pbxSdp(payloads: '0 101', direction: 'sendonly')));
      final ok = await pbx.response(200, method: 'INVITE');
      expect(ok.body, contains('a=recvonly'));
      pbx.send(inDialog('ACK', 103));
      await eventually(() => events.contains('$callId:remoteHeld'));
      expect(media.micStops, greaterThan(0));

      // A session refresh with the same direction does not repeat the event.
      pbx.send(inDialog('INVITE', 104,
          body: pbxSdp(payloads: '0 101', direction: 'sendonly')));
      await pbx.response(200, method: 'INVITE');
      pbx.send(inDialog('ACK', 104));

      pbx.send(inDialog('INVITE', 105, body: pbxSdp(payloads: '0 101')));
      final ok2 = await pbx.response(200, method: 'INVITE');
      expect(ok2.body, contains('a=sendrecv'));
      pbx.send(inDialog('ACK', 105));
      await eventually(() => events.contains('$callId:remoteResumed'));
      expect(events.where((e) => e.endsWith(':remoteHeld')), hasLength(1));
      expect(media.micStarts, starts + 1);
      expect(events, isNot(contains('$callId:ended')));
    });

    test('local hold with auth challenge, then resume', () async {
      await answered();
      final hold = client.holdCall(callId);
      final inv1 = await pbx.request('INVITE');
      expect(inv1.requestUri, 'sip:2000@127.0.0.1:${pbx.port}');
      expect(inv1.header('Route'), '<sip:127.0.0.1:${pbx.port};lr>');
      expect(inv1.cseqNumber, 2);
      expect(extractTag(inv1.from!), localTag);
      expect(extractTag(inv1.to!), 'pbxtag');
      expect(inv1.body, contains('a=sendonly'));

      pbx.send(pbx.respond(inv1, 401, 'Unauthorized',
          headers: ['WWW-Authenticate: Digest realm="asterisk", nonce="h1"']));
      final ack1 = await pbx.request('ACK');
      expect(ack1.cseqNumber, 2);
      expect(_branch(ack1), _branch(inv1));

      final inv2 = await pbx.request('INVITE');
      expect(inv2.cseqNumber, 3);
      final auth = _params(inv2.header('Authorization')!);
      expect(auth['uri'], inv2.requestUri);
      final ha1 = _md5('1001:asterisk:secret');
      final ha2 = _md5('INVITE:${inv2.requestUri}');
      expect(auth['response'], _md5('$ha1:h1:$ha2'));

      final ok = pbx.respond(inv2, 200, 'OK',
          body: pbxSdp(payloads: '0 101', direction: 'recvonly'));
      pbx.send(ok);
      final ack2 = await pbx.request('ACK');
      expect(ack2.cseqNumber, 3);
      expect(ack2.header('Route'), '<sip:127.0.0.1:${pbx.port};lr>');
      expect(await hold, isTrue);
      expect(events, contains('$callId:held'));

      // Retransmitted 200 OK: ACK again, no second event.
      pbx.send(ok);
      await pbx.request('ACK');
      expect(events.where((e) => e.endsWith(':held')), hasLength(1));

      final starts = media.micStarts;
      final resume = client.unholdCall(callId);
      final inv3 = await pbx.request('INVITE');
      expect(inv3.cseqNumber, 4);
      expect(inv3.body, contains('a=sendrecv'));
      pbx.send(pbx.respond(inv3, 200, 'OK', body: pbxSdp(payloads: '0 101', port: 30002)));
      final ack3 = await pbx.request('ACK');
      expect(ack3.cseqNumber, 4);
      expect(await resume, isTrue);
      expect(events, contains('$callId:resumed'));
      expect(media.micStarts, starts + 1);
      expect(media.remotes.last, '127.0.0.1:30002/0/101');
    });

    test('glare: a re-INVITE during our hold gets 491', () async {
      await answered();
      client.holdCall(callId);
      await pbx.request('INVITE');
      pbx.send(inDialog('INVITE', 103, body: pbxSdp(payloads: '0 101')));
      await pbx.response(491, method: 'INVITE');
    });

    test('hold failure gives the microphone back', () async {
      await answered();
      final starts = media.micStarts;
      final hold = client.holdCall(callId);
      final inv = await pbx.request('INVITE');
      pbx.send(pbx.respond(inv, 488, 'Not Acceptable Here'));
      expect(await hold, isFalse);
      await pbx.request('ACK');
      expect(media.micStarts, starts + 1);
      expect(errors.last, contains('Hold failed'));
      expect(client.activeCalls.containsKey(callId), isTrue);
    });

    test('DTMF goes out as RTP telephone-event when negotiated', () async {
      await answered();
      await client.sendDtmf(callId, '5#x');
      expect(media.dtmf, ['5', '#']);
    });

    test('remote BYE ends the call and releases audio', () async {
      await answered();
      pbx.send(inDialog('BYE', 103));
      await pbx.response(200, method: 'BYE');
      await eventually(() => events.contains('$callId:ended'));
      expect(media.releases, greaterThan(0));
      expect(client.activeCalls, isEmpty);
    });

    test('local hangup sends BYE with the route set', () async {
      await answered();
      await client.hangupCall(callId);
      expect(events.last, '$callId:ended');
      final bye = await pbx.request('BYE');
      expect(bye.cseqNumber, 2);
      expect(bye.header('Route'), '<sip:127.0.0.1:${pbx.port};lr>');
      pbx.send(pbx.respond(bye, 200, 'OK'));
      await eventually(() => client.activeCalls.isEmpty);
    });

    test('caller hangs up while ringing (CANCEL)', () async {
      await register();
      await sendInvite(sdp: pbxSdp());
      final ringing = await pbx.response(180);
      localTag = extractTag(ringing.to!)!;
      pbx.send(pbx.requestTo('CANCEL',
          callId: callId,
          cseq: 102,
          from: remoteFrom,
          to: '<sip:1001@127.0.0.1>',
          branch: 'z9hG4bKinv102'));
      await pbx.response(200, method: 'CANCEL');
      final terminated = await pbx.response(487, method: 'INVITE');
      expect(extractTag(terminated.to!), localTag);
      await eventually(() => events.contains('$callId:cancelled'));
    });

    test('reject while ringing sends 486', () async {
      await register();
      await sendInvite(sdp: pbxSdp());
      await pbx.response(180);
      await client.hangupCall(callId);
      await pbx.response(486, method: 'INVITE');
      expect(events, ['$callId:ended']);
    });

    test('offer without a G.711 codec is refused with 488', () async {
      await register();
      await sendInvite(sdp: pbxSdp(payloads: '18 101'));
      await pbx.response(488, method: 'INVITE');
      expect(incoming, isEmpty);
    });

    test('delayed offer: we offer in 200 OK, the answer comes in ACK',
        () async {
      await register();
      await sendInvite();
      final ringing = await pbx.response(180);
      localTag = extractTag(ringing.to!)!;
      await client.answerCall(callId);
      final ok = await pbx.response(200, method: 'INVITE');
      expect(ok.body, contains('m=audio 40000 RTP/AVP 8 0 101'));
      pbx.send(inDialog('ACK', 102, body: pbxSdp(payloads: '0', port: 30500)));
      await eventually(() => events.contains('$callId:confirmed'));
      expect(media.remotes.last, '127.0.0.1:30500/0/-');
    });
  });

  group('outgoing call', () {
    late String callId;
    late SipMessage invite;

    Future<void> dial() async {
      await register();
      callId = await client.makeCall('2001');
      invite = await pbx.request('INVITE');
    }

    Future<void> established({String answerPayloads = '8 101'}) async {
      await dial();
      pbx.send(pbx.respond(invite, 180, 'Ringing', toTag: 'callee'));
      pbx.send(pbx.respond(invite, 200, 'OK', toTag: 'callee', headers: [
        'Contact: <sip:2001@127.0.0.1:${pbx.port}>',
      ], body: pbxSdp(payloads: answerPayloads, port: 30010)));
      await pbx.request('ACK');
      await eventually(() => events.contains('$callId:confirmed'));
      pbx.clearInbox();
    }

    test('407 challenge, ringing, answer with route set, hangup', () async {
      await dial();
      expect(events, ['$callId:calling']);
      expect(invite.requestUri, 'sip:2001@127.0.0.1');
      expect(invite.cseqNumber, 1);
      expect(invite.body, contains('m=audio 40000 RTP/AVP 8 0 101'));

      pbx.send(pbx.respond(invite, 407, 'Proxy Authentication Required',
          toTag: 'x',
          headers: ['Proxy-Authenticate: Digest realm="asterisk", nonce="p1"']));
      final ack = await pbx.request('ACK');
      expect(_branch(ack), _branch(invite));
      expect(ack.cseqNumber, 1);
      expect(ack.requestUri, invite.requestUri);

      final invite2 = await pbx.request('INVITE');
      expect(invite2.cseqNumber, 2);
      expect(invite2.callId, invite.callId);
      expect(extractTag(invite2.from!), extractTag(invite.from!));
      final auth = _params(invite2.header('Proxy-Authorization')!);
      expect(auth['response'],
          _md5('${_md5('1001:asterisk:secret')}:p1:${_md5('INVITE:sip:2001@127.0.0.1')}'));

      pbx.send(pbx.respond(invite2, 100, 'Trying'));
      pbx.send(pbx.respond(invite2, 180, 'Ringing', toTag: 'callee'));
      await eventually(() => events.contains('$callId:ringing'));

      pbx.send(pbx.respond(invite2, 200, 'OK', toTag: 'callee', headers: [
        'Contact: <sip:2001@127.0.0.1:${pbx.port}>',
        'Record-Route: <sip:127.0.0.1:${pbx.port};lr>, <sip:10.0.0.9;lr>',
      ], body: pbxSdp(payloads: '8 101', port: 30010)));
      final ack2 = await pbx.request('ACK');
      expect(ack2.requestUri, 'sip:2001@127.0.0.1:${pbx.port}');
      expect(ack2.headerAll('Route'),
          ['<sip:10.0.0.9;lr>', '<sip:127.0.0.1:${pbx.port};lr>']);
      expect(ack2.cseqNumber, 2);
      expect(extractTag(ack2.to!), 'callee');
      await eventually(() => events.contains('$callId:confirmed'));
      expect(media.remotes.last, '127.0.0.1:30010/8/101');
      expect(media.micStarts, 1);

      await client.hangupCall(callId);
      expect(events.last, '$callId:ended');
      final bye = await pbx.request('BYE');
      expect(bye.cseqNumber, 3);
      expect(bye.headerAll('Route'), hasLength(2));
      pbx.send(pbx.respond(bye, 200, 'OK'));
      await eventually(() => client.activeCalls.isEmpty);
      expect(events.where((e) => e.endsWith(':ended')), hasLength(1));
    });

    test('hangup while ringing sends CANCEL and ACKs the 487', () async {
      await dial();
      pbx.send(pbx.respond(invite, 100, 'Trying'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await client.hangupCall(callId);
      expect(events.last, '$callId:ended');
      final cancel = await pbx.request('CANCEL');
      expect(_branch(cancel), _branch(invite));
      expect(cancel.cseqNumber, invite.cseqNumber);
      expect(cancel.requestUri, invite.requestUri);
      pbx.send(pbx.respond(cancel, 200, 'OK'));
      pbx.send(pbx.respond(invite, 487, 'Request Terminated', toTag: 'callee'));
      final ack = await pbx.request('ACK');
      expect(_branch(ack), _branch(invite));
      await eventually(() => client.activeCalls.isEmpty);
      expect(events.where((e) => e.endsWith(':ended')), hasLength(1));
    });

    test('CANCEL waits for the first provisional response', () async {
      await dial();
      await client.hangupCall(callId);
      await pbx.expectNothing((m) => m.method == 'CANCEL',
          within: const Duration(milliseconds: 300));
      pbx.send(pbx.respond(invite, 180, 'Ringing', toTag: 'callee'));
      await pbx.request('CANCEL');
    });

    test('a 200 OK that crosses our CANCEL is ACKed and hung up', () async {
      await dial();
      pbx.send(pbx.respond(invite, 180, 'Ringing', toTag: 'callee'));
      await eventually(() => events.contains('$callId:ringing'));
      await client.hangupCall(callId);
      await pbx.request('CANCEL');
      pbx.send(pbx.respond(invite, 200, 'OK', toTag: 'callee',
          headers: ['Contact: <sip:2001@127.0.0.1:${pbx.port}>'],
          body: pbxSdp()));
      final ack = await pbx.request('ACK');
      expect(ack.cseqNumber, invite.cseqNumber);
      final bye = await pbx.request('BYE');
      expect(extractTag(bye.to!), 'callee');
      expect(events, isNot(contains('$callId:confirmed')));
    });

    test('busy is reported as declined', () async {
      await dial();
      pbx.send(pbx.respond(invite, 486, 'Busy Here', toTag: 'callee'));
      await pbx.request('ACK');
      await eventually(() => events.contains('$callId:declined'));
      expect(client.activeCalls, isEmpty);
    });

    test('not found is reported as failed with the reason', () async {
      await dial();
      pbx.send(pbx.respond(invite, 404, 'Not Found', toTag: 'callee'));
      await pbx.request('ACK');
      await eventually(() => events.contains('$callId:failed'));
      expect(errors.last, contains('404 Not Found'));
    });

    test('early media from 183 is played before the answer', () async {
      await dial();
      pbx.send(pbx.respond(invite, 183, 'Session Progress',
          toTag: 'callee', body: pbxSdp(payloads: '8', port: 30777)));
      await eventually(() => events.contains('$callId:ringing'));
      expect(media.remotes.last, '127.0.0.1:30777/8/-');
    });

    test('blind transfer with REFER and NOTIFY', () async {
      await established();
      final accepted = client.transferCall(callId, '3000');
      final refer = await pbx.request('REFER');
      expect(refer.header('Refer-To'), '<sip:3000@127.0.0.1>');
      expect(refer.header('Referred-By'), '<sip:1001@127.0.0.1>');
      expect(refer.cseqNumber, invite.cseqNumber! + 1);
      pbx.send(pbx.respond(refer, 202, 'Accepted'));
      expect(await accepted, isTrue);

      pbx.send(pbx.requestTo('NOTIFY',
          callId: invite.callId!,
          cseq: 1,
          from: '${invite.to!};tag=callee',
          to: invite.from!,
          headers: ['Event: refer', 'Subscription-State: terminated'],
          body: 'SIP/2.0 200 OK\r\n',
          contentType: 'message/sipfrag'));
      await pbx.response(200, method: 'NOTIFY');
      final bye = await pbx.request('BYE');
      pbx.send(pbx.respond(bye, 200, 'OK'));
      await eventually(() => events.contains('$callId:ended'));
      expect(events, contains('$callId:transferred'));
    });

    test('refused transfer keeps the call', () async {
      await established();
      final accepted = client.transferCall(callId, '3000');
      final refer = await pbx.request('REFER');
      pbx.send(pbx.respond(refer, 603, 'Declined'));
      expect(await accepted, isFalse);
      expect(errors.last, contains('Transfer refused'));
      expect(client.activeCalls.containsKey(callId), isTrue);
    });

    test('DTMF falls back to SIP INFO without telephone-event', () async {
      await established(answerPayloads: '8');
      await client.sendDtmf(callId, '7');
      final info = await pbx.request('INFO');
      expect(info.header('Content-Type'), 'application/dtmf-relay');
      expect(info.body, contains('Signal=7'));
      expect(media.dtmf, isEmpty);
    });

    test('two calls: hanging up the held one keeps the live one', () async {
      await established();
      final first = callId;
      final hold = client.holdCall(first);
      final reinv = await pbx.request('INVITE');
      pbx.send(pbx.respond(reinv, 200, 'OK',
          body: pbxSdp(payloads: '8 101', port: 30010, direction: 'recvonly')));
      await pbx.request('ACK');
      expect(await hold, isTrue);

      final second = await client.makeCall('2002');
      final inv2 = await pbx.request('INVITE');
      pbx.send(pbx.respond(inv2, 200, 'OK', toTag: 'c2',
          headers: ['Contact: <sip:2002@127.0.0.1:${pbx.port}>'],
          body: pbxSdp(payloads: '8 101', port: 30020)));
      await pbx.request('ACK');
      await eventually(() => events.contains('$second:confirmed'));
      expect(media.ignored, {'127.0.0.1:30010'});

      final releases = media.releases;
      final stops = media.micStops;
      await client.hangupCall(first);
      expect(media.releases, releases);
      expect(media.micStops, stops);
      expect(client.activeCalls.keys, [second]);
    });
  });

  test('calls without registration are refused', () async {
    expect(() => client.makeCall('2000'), throwsStateError);
  });

  test('SipCallEvent legacy names', () {
    expect(SipCallEvent.remoteHeld.legacyName, 'REMOTE_HELD');
    expect(SipCallEvent.cancelled.legacyName, 'CANCELED');
    expect(SipCallEvent.ended.isTerminal, isTrue);
    expect(SipCallEvent.held.isTerminal, isFalse);
  });
}
