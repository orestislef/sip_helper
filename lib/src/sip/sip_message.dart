/// Minimal SIP message parser and header helpers.
///
/// Header names are matched case-insensitively and compact forms
/// (`i:`, `f:`, `t:`, `v:`, `m:` ...) are understood, as RFC 3261 requires.
library;

const Map<String, String> _compactForms = {
  'i': 'call-id',
  'f': 'from',
  't': 'to',
  'v': 'via',
  'm': 'contact',
  'l': 'content-length',
  'c': 'content-type',
  'e': 'content-encoding',
  'k': 'supported',
  's': 'subject',
  'o': 'event',
  'r': 'refer-to',
  'b': 'referred-by',
  'x': 'session-expires',
  'u': 'allow-events',
};

String _canonical(String name) {
  final lower = name.trim().toLowerCase();
  return _compactForms[lower] ?? lower;
}

/// A parsed SIP request or response.
class SipMessage {
  /// First line, e.g. `INVITE sip:1001@pbx SIP/2.0` or `SIP/2.0 200 OK`.
  final String startLine;

  /// Headers in the order received. Names are kept as received, values are
  /// trimmed. A header that appears on several lines appears several times.
  final List<MapEntry<String, String>> headers;

  /// Message body ('' when there is none). Line endings are `\n`.
  final String body;

  SipMessage._(this.startLine, this.headers, this.body);

  /// Parse [raw]. Returns null for keep-alive pings and anything that is not
  /// a SIP message.
  static SipMessage? parse(String raw) {
    // Leading blank lines are keep-alive noise (RFC 5626 CRLF pings).
    final text = raw.replaceAll('\r', '').replaceFirst(RegExp(r'^\s+'), '');
    if (text.isEmpty) return null;
    final split = text.indexOf('\n\n');
    final head = split == -1 ? text : text.substring(0, split);
    final body = split == -1 ? '' : text.substring(split + 2);
    final lines = head.split('\n');
    final start = lines.first.trim();
    if (!start.startsWith('SIP/2.0 ') && !start.endsWith(' SIP/2.0')) {
      return null;
    }
    final headers = <MapEntry<String, String>>[];
    for (final line in lines.skip(1)) {
      if (line.isEmpty) continue;
      // Folded continuation line (RFC 3261 7.3.1).
      if ((line.startsWith(' ') || line.startsWith('\t')) &&
          headers.isNotEmpty) {
        final last = headers.removeLast();
        headers.add(MapEntry(last.key, '${last.value} ${line.trim()}'));
        continue;
      }
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      headers.add(MapEntry(
        line.substring(0, colon).trim(),
        line.substring(colon + 1).trim(),
      ));
    }
    // Over UDP the datagram boundary ends the body, so Content-Length is not
    // needed to find it.
    return SipMessage._(start, headers, body);
  }

  /// True for responses (`SIP/2.0 ...`).
  bool get isResponse => startLine.startsWith('SIP/2.0 ');

  /// Status code of a response, null for requests.
  int? get statusCode {
    if (!isResponse) return null;
    final parts = startLine.split(' ');
    return parts.length > 1 ? int.tryParse(parts[1]) : null;
  }

  /// Reason phrase of a response ('' for requests).
  String get reasonPhrase {
    if (!isResponse) return '';
    final parts = startLine.split(' ');
    return parts.length > 2 ? parts.sublist(2).join(' ') : '';
  }

  /// Method of a request, null for responses.
  String? get method => isResponse ? null : startLine.split(' ').first;

  /// Request-URI of a request, null for responses.
  String? get requestUri {
    if (isResponse) return null;
    final parts = startLine.split(' ');
    return parts.length > 1 ? parts[1] : null;
  }

  /// First value of header [name] (case-insensitive, compact forms ok).
  String? header(String name) {
    final want = _canonical(name);
    for (final h in headers) {
      if (_canonical(h.key) == want) return h.value;
    }
    return null;
  }

  /// Every value of header [name], one entry per header line.
  List<String> headerAll(String name) {
    final want = _canonical(name);
    return [
      for (final h in headers)
        if (_canonical(h.key) == want) h.value,
    ];
  }

  /// Every value of header [name], with comma separated lines split into
  /// individual values (commas inside <> or quotes are respected).
  List<String> headerValues(String name) {
    final out = <String>[];
    for (final v in headerAll(name)) {
      out.addAll(splitHeaderList(v));
    }
    return out;
  }

  String? get callId => header('Call-ID');
  String? get from => header('From');
  String? get to => header('To');
  String? get topVia {
    final all = headerValues('Via');
    return all.isEmpty ? null : all.first;
  }

  /// CSeq sequence number.
  int? get cseqNumber {
    final v = header('CSeq');
    if (v == null) return null;
    return int.tryParse(v.trim().split(RegExp(r'\s+')).first);
  }

  /// CSeq method, e.g. `INVITE`.
  String? get cseqMethod {
    final v = header('CSeq');
    if (v == null) return null;
    final parts = v.trim().split(RegExp(r'\s+'));
    return parts.length > 1 ? parts[1].toUpperCase() : null;
  }

  /// True when the body carries an SDP audio description.
  bool get hasSdp => body.contains('m=audio');
}

/// Split a comma separated header value, respecting `<...>` and quotes.
List<String> splitHeaderList(String value) {
  final out = <String>[];
  var depth = 0;
  var quoted = false;
  final buf = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    if (ch == '"' && (i == 0 || value[i - 1] != '\\')) quoted = !quoted;
    if (!quoted) {
      if (ch == '<') depth++;
      if (ch == '>') depth--;
      if (ch == ',' && depth == 0) {
        final s = buf.toString().trim();
        if (s.isNotEmpty) out.add(s);
        buf.clear();
        continue;
      }
    }
    buf.write(ch);
  }
  final s = buf.toString().trim();
  if (s.isNotEmpty) out.add(s);
  return out;
}

/// The `tag` parameter of a From/To value, or null.
String? extractTag(String headerValue) {
  final m = RegExp(r';\s*tag=([^\s;>,]+)', caseSensitive: false)
      .firstMatch(headerValue);
  return m?.group(1);
}

/// [headerValue] without its `tag` parameter.
String stripTag(String headerValue) {
  return headerValue
      .replaceAll(RegExp(r';\s*tag=[^\s;>,]+', caseSensitive: false), '')
      .trim();
}

/// The SIP URI inside a header value (`<sip:...>` or a bare `sip:...`).
String? extractUri(String headerValue) {
  final angle = RegExp(r'<([^>]+)>').firstMatch(headerValue);
  if (angle != null) return angle.group(1)!.trim();
  final bare =
      RegExp(r'(sips?:[^\s;,>]+)', caseSensitive: false).firstMatch(headerValue);
  return bare?.group(1);
}

/// User part of a SIP URI or header value (`1001` in `sip:1001@pbx`).
String? extractUser(String headerValue) {
  final uri = extractUri(headerValue) ?? headerValue;
  final m = RegExp(r'^sips?:([^@;>]+)@', caseSensitive: false).firstMatch(uri);
  if (m != null) return Uri.decodeComponent(m.group(1)!);
  return null;
}

/// Display name of a From/To value (`John` in `"John" <sip:...>`), or null.
String? extractDisplayName(String headerValue) {
  final quoted = RegExp(r'^\s*"((?:[^"\\]|\\.)*)"').firstMatch(headerValue);
  if (quoted != null) {
    final name = quoted.group(1)!.replaceAll(r'\"', '"').trim();
    return name.isEmpty ? null : name;
  }
  final plain = RegExp(r'^\s*([^<"]+?)\s*<').firstMatch(headerValue);
  if (plain != null) {
    final name = plain.group(1)!.trim();
    return name.isEmpty ? null : name;
  }
  return null;
}

/// A `;name=value` parameter of a header value (Via branch, received, ...).
/// Returns '' for a parameter present without a value, null when absent.
String? headerParam(String headerValue, String name) {
  final m = RegExp(';\\s*$name(?:=([^;,\\s>]*))?(?=[;,\\s>]|\$)',
          caseSensitive: false)
      .firstMatch(headerValue);
  if (m == null) return null;
  return m.group(1) ?? '';
}

/// Quote a display name for use in From/To headers.
String quoteDisplayName(String name) {
  final escaped = name.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}
