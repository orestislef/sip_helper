import 'package:flutter_test/flutter_test.dart';
import 'package:sip_helper/src/sip/sip_message.dart';

void main() {
  group('SipMessage.parse', () {
    test('parses a request with CRLF line endings and a body', () {
      final raw = [
        'INVITE sip:1001@10.0.0.2:5062 SIP/2.0',
        'Via: SIP/2.0/UDP 10.0.0.1:5060;branch=z9hG4bKa;rport',
        'Via: SIP/2.0/UDP 10.0.0.9:5060;branch=z9hG4bKb',
        'From: "Alice" <sip:2000@pbx>;tag=abc',
        'To: <sip:1001@pbx>',
        'Call-ID: xyz@pbx',
        'CSeq: 102 INVITE',
        'Content-Type: application/sdp',
        'Content-Length: 10',
        '',
        'v=0',
        'm=audio 1 RTP/AVP 0',
        '',
      ].join('\r\n');
      final m = SipMessage.parse(raw)!;
      expect(m.isResponse, isFalse);
      expect(m.method, 'INVITE');
      expect(m.requestUri, 'sip:1001@10.0.0.2:5062');
      expect(m.callId, 'xyz@pbx');
      expect(m.cseqNumber, 102);
      expect(m.cseqMethod, 'INVITE');
      expect(m.headerAll('Via'), hasLength(2));
      expect(m.topVia, contains('z9hG4bKa'));
      expect(m.hasSdp, isTrue);
    });

    test('header names are case-insensitive and compact forms work', () {
      final raw = 'SIP/2.0 200 OK\r\n'
          'v: SIP/2.0/UDP 1.2.3.4;branch=z9hG4bKx\r\n'
          'f: <sip:a@b>;tag=1\r\n'
          't: <sip:c@d>;tag=2\r\n'
          'i: abc\r\n'
          'CSEQ: 7 REGISTER\r\n'
          'm: <sip:a@1.2.3.4:5060>;expires=300\r\n'
          'l: 0\r\n\r\n';
      final m = SipMessage.parse(raw)!;
      expect(m.isResponse, isTrue);
      expect(m.statusCode, 200);
      expect(m.reasonPhrase, 'OK');
      expect(m.callId, 'abc');
      expect(m.header('call-id'), 'abc');
      expect(m.header('Contact'), contains('expires=300'));
      expect(m.cseqMethod, 'REGISTER');
      expect(m.topVia, contains('z9hG4bKx'));
    });

    test('folded header lines are joined', () {
      final m = SipMessage.parse('OPTIONS sip:a@b SIP/2.0\r\n'
          'Subject: hello\r\n'
          '  world\r\n'
          'Call-ID: 1\r\n\r\n')!;
      expect(m.header('Subject'), 'hello world');
    });

    test('keep-alive pings and junk are ignored', () {
      expect(SipMessage.parse('\r\n\r\n'), isNull);
      expect(SipMessage.parse('\r\n'), isNull);
      expect(SipMessage.parse('hello there'), isNull);
    });

    test('leading blank lines before a message are skipped', () {
      final m = SipMessage.parse('\r\n\r\nBYE sip:a@b SIP/2.0\r\nCall-ID: 9\r\n\r\n');
      expect(m?.method, 'BYE');
    });

    test('comma separated header values are split, URIs stay whole', () {
      final m = SipMessage.parse('SIP/2.0 200 OK\r\n'
          'Record-Route: <sip:p1;lr>, <sip:p2;lr>\r\n'
          'Record-Route: <sip:p3;lr>\r\n'
          'Contact: "A, B" <sip:x@y>\r\n\r\n')!;
      expect(m.headerValues('Record-Route'),
          ['<sip:p1;lr>', '<sip:p2;lr>', '<sip:p3;lr>']);
      expect(m.headerValues('Contact'), ['"A, B" <sip:x@y>']);
    });
  });

  group('header helpers', () {
    test('tags', () {
      expect(extractTag('<sip:1@a>;tag=abc'), 'abc');
      expect(extractTag('<sip:1@a>;TAG=abc;foo=1'), 'abc');
      expect(extractTag('<sip:1@a>'), isNull);
      expect(stripTag('"A" <sip:1@a>;tag=abc'), '"A" <sip:1@a>');
    });

    test('uris, users and display names', () {
      expect(extractUri('"A" <sip:1001@pbx:5060;transport=udp>;tag=1'),
          'sip:1001@pbx:5060;transport=udp');
      expect(extractUri('sip:1001@pbx;tag=1'), 'sip:1001@pbx');
      expect(extractUser('"A" <sip:1001@pbx>'), '1001');
      expect(extractUser('<sip:%2B30210@pbx>'), '+30210');
      expect(extractDisplayName('"Alice Smith" <sip:1@a>'), 'Alice Smith');
      expect(extractDisplayName('Bob <sip:1@a>'), 'Bob');
      expect(extractDisplayName('<sip:1@a>'), isNull);
      expect(extractDisplayName('"" <sip:1@a>'), isNull);
    });

    test('parameters', () {
      const via = 'SIP/2.0/UDP 10.0.0.2:5062;rport=40000;received=1.2.3.4;branch=z9hG4bKq';
      expect(headerParam(via, 'branch'), 'z9hG4bKq');
      expect(headerParam(via, 'received'), '1.2.3.4');
      expect(headerParam(via, 'rport'), '40000');
      expect(headerParam('SIP/2.0/UDP a;rport;branch=x', 'rport'), '');
      expect(headerParam(via, 'maddr'), isNull);
    });

    test('display names are quoted and escaped', () {
      expect(quoteDisplayName('John "JJ" Doe'), r'"John \"JJ\" Doe"');
    });
  });
}
