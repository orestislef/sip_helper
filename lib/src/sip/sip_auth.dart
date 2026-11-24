/// SIP digest authentication (RFC 2617, RFC 8760).
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A parsed `WWW-Authenticate` or `Proxy-Authenticate` challenge.
class DigestChallenge {
  final String realm;
  final String nonce;
  final String? opaque;

  /// `MD5`, `MD5-sess`, `SHA-256` or `SHA-256-sess`.
  final String algorithm;

  /// The qop values offered (`auth`, `auth-int`), empty for legacy RFC 2069.
  final List<String> qop;
  final bool stale;

  /// True for a 407 `Proxy-Authenticate` challenge, which must be answered
  /// with `Proxy-Authorization`.
  final bool isProxy;

  /// How many times this nonce has been used (the `nc` value).
  int nonceCount = 0;

  DigestChallenge({
    required this.realm,
    required this.nonce,
    this.opaque,
    this.algorithm = 'MD5',
    this.qop = const [],
    this.stale = false,
    this.isProxy = false,
  });

  /// Parse one challenge header value. Returns null when it is not a digest
  /// challenge we can answer.
  static DigestChallenge? parse(String headerValue, {bool isProxy = false}) {
    final v = headerValue.trim();
    if (!v.toLowerCase().startsWith('digest')) return null;
    final params = _parseParams(v.substring(6));
    final realm = params['realm'];
    final nonce = params['nonce'];
    if (realm == null || nonce == null) return null;
    final algorithm = (params['algorithm'] ?? 'MD5').toUpperCase();
    if (!_supported.contains(algorithm)) return null;
    final qop =
        (params['qop'] ?? '')
            .split(',')
            .map((s) => s.trim().toLowerCase())
            .where((s) => s.isNotEmpty)
            .toList();
    return DigestChallenge(
      realm: realm,
      nonce: nonce,
      opaque: params['opaque'],
      algorithm: algorithm,
      qop: qop,
      stale: (params['stale'] ?? '').toLowerCase() == 'true',
      isProxy: isProxy,
    );
  }

  /// Pick the best challenge among several header values (SHA-256 is
  /// preferred over MD5 when a server offers both).
  static DigestChallenge? pick(List<String> values, {bool isProxy = false}) {
    DigestChallenge? best;
    for (final v in values) {
      final c = parse(v, isProxy: isProxy);
      if (c == null) continue;
      if (best == null ||
          (c.algorithm.startsWith('SHA-256') &&
              !best.algorithm.startsWith('SHA-256'))) {
        best = c;
      }
    }
    return best;
  }

  /// Header name to answer this challenge with.
  String get responseHeaderName =>
      isProxy ? 'Proxy-Authorization' : 'Authorization';

  /// Build the credentials header value for [method] on [uri].
  ///
  /// [cnonce] can be fixed for tests, otherwise a random one is generated.
  String authorize({
    required String method,
    required String uri,
    required String username,
    required String password,
    String body = '',
    String? cnonce,
  }) {
    String h(String s) =>
        algorithm.startsWith('SHA-256')
            ? sha256.convert(utf8.encode(s)).toString()
            : md5.convert(utf8.encode(s)).toString();

    final useQop =
        qop.contains('auth')
            ? 'auth'
            : (qop.contains('auth-int') ? 'auth-int' : null);
    nonceCount++;
    final nc = nonceCount.toRadixString(16).padLeft(8, '0');
    final cn = cnonce ?? _randomHex(16);

    var ha1 = h('$username:$realm:$password');
    if (algorithm.endsWith('-SESS')) {
      ha1 = h('$ha1:$nonce:$cn');
    }
    final ha2 =
        useQop == 'auth-int' ? h('$method:$uri:${h(body)}') : h('$method:$uri');
    final response =
        useQop == null
            ? h('$ha1:$nonce:$ha2')
            : h('$ha1:$nonce:$nc:$cn:$useQop:$ha2');

    final b =
        StringBuffer()
          ..write('Digest username="$username", realm="$realm", ')
          ..write('nonce="$nonce", uri="$uri", response="$response", ')
          ..write('algorithm=$algorithm');
    if (opaque != null) b.write(', opaque="$opaque"');
    if (useQop != null) b.write(', qop=$useQop, nc=$nc, cnonce="$cn"');
    return b.toString();
  }

  static const _supported = {'MD5', 'MD5-SESS', 'SHA-256', 'SHA-256-SESS'};

  static final Random _rng = Random.secure();

  static String _randomHex(int length) {
    const chars = '0123456789abcdef';
    return List.generate(length, (_) => chars[_rng.nextInt(16)]).join();
  }

  static Map<String, String> _parseParams(String s) {
    final out = <String, String>{};
    final re = RegExp(
      r'([A-Za-z0-9_-]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^,\s]+))',
    );
    for (final m in re.allMatches(s)) {
      out[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
    }
    return out;
  }
}
