import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sip_helper/src/sip/sip_auth.dart';

String _md5(String s) => md5.convert(utf8.encode(s)).toString();

Map<String, String> _params(String header) {
  final out = <String, String>{};
  for (final m in RegExp(r'(\w+)=(?:"([^"]*)"|([^,\s]+))').allMatches(header)) {
    out[m.group(1)!] = m.group(2) ?? m.group(3)!;
  }
  return out;
}

void main() {
  test('RFC 2617 reference vector (qop=auth)', () {
    final c = DigestChallenge.parse(
        'Digest realm="testrealm@host.com", qop="auth,auth-int", '
        'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", '
        'opaque="5ccc069c403ebaf9f0171e9517f40e41"')!;
    final header = c.authorize(
      method: 'GET',
      uri: '/dir/index.html',
      username: 'Mufasa',
      password: 'Circle Of Life',
      cnonce: '0a4f113b',
    );
    final p = _params(header);
    expect(p['response'], '6629fae49393a05397450978507c4ef1');
    expect(p['nc'], '00000001');
    expect(p['qop'], 'auth');
    expect(p['opaque'], '5ccc069c403ebaf9f0171e9517f40e41');
  });

  test('legacy challenge without qop', () {
    final c = DigestChallenge.parse(
        'Digest algorithm=MD5, realm="asterisk", nonce="1a2b3c"')!;
    final header = c.authorize(
        method: 'REGISTER',
        uri: 'sip:pbx.example.com',
        username: '1001',
        password: 'secret');
    final ha1 = _md5('1001:asterisk:secret');
    final ha2 = _md5('REGISTER:sip:pbx.example.com');
    final p = _params(header);
    expect(p['response'], _md5('$ha1:1a2b3c:$ha2'));
    expect(header, isNot(contains('qop')));
    expect(header, isNot(contains('opaque')));
  });

  test('nonce count increases when a nonce is reused', () {
    final c = DigestChallenge.parse('Digest realm="r", nonce="n", qop=auth')!;
    String nc() => _params(c.authorize(
        method: 'REGISTER', uri: 'sip:x', username: 'u', password: 'p'))['nc']!;
    expect(nc(), '00000001');
    expect(nc(), '00000002');
  });

  test('stale flag, proxy header name and unsupported algorithms', () {
    final c = DigestChallenge.parse('Digest realm="r", nonce="n", stale=TRUE',
        isProxy: true)!;
    expect(c.stale, isTrue);
    expect(c.responseHeaderName, 'Proxy-Authorization');
    expect(DigestChallenge.parse('Basic realm="r"'), isNull);
    expect(DigestChallenge.parse('Digest realm="r", nonce="n", algorithm=AKAv1-MD5'),
        isNull);
  });

  test('SHA-256 is preferred when offered next to MD5', () {
    final c = DigestChallenge.pick([
      'Digest realm="r", nonce="n", algorithm=MD5',
      'Digest realm="r", nonce="n", algorithm=SHA-256',
    ])!;
    expect(c.algorithm, 'SHA-256');
    final p = _params(c.authorize(
        method: 'INVITE', uri: 'sip:1@r', username: 'u', password: 'p'));
    String h(String s) => sha256.convert(utf8.encode(s)).toString();
    expect(p['response'], h('${h('u:r:p')}:n:${h('INVITE:sip:1@r')}'));
  });
}
