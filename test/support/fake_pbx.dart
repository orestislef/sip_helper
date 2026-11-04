import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sip_helper/src/net/datagram_sender.dart';
import 'package:sip_helper/src/sip/sip_media.dart';
import 'package:sip_helper/src/sip/sip_message.dart';

/// A scripted SIP server on loopback. Tests read what the client sent and
/// write raw SIP back.
class FakePbx {
  final RawDatagramSocket socket;
  late final DatagramSender _sender = DatagramSender(socket);
  InternetAddress? clientAddress;
  int? clientPort;
  final List<SipMessage> _inbox = [];
  final List<_Waiter> _waiters = [];
  final List<SipMessage> all = [];

  FakePbx._(this.socket) {
    socket.listen((event) {
      if (event == RawSocketEvent.write) {
        _sender.onWrite();
        return;
      }
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = socket.receive()) != null) {
        clientAddress = d!.address;
        clientPort = d.port;
        final msg = SipMessage.parse(utf8.decode(d.data));
        if (msg == null) continue;
        all.add(msg);
        final w = _waiters.where((w) => w.test(msg)).firstOrNull;
        if (w != null) {
          _waiters.remove(w);
          w.completer.complete(msg);
        } else {
          _inbox.add(msg);
        }
      }
    });
  }

  static Future<FakePbx> start() async =>
      FakePbx._(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));

  int get port => socket.port;

  /// The next message matching [test] (already received or still to come).
  Future<SipMessage> next(bool Function(SipMessage m) test,
      {Duration timeout = const Duration(seconds: 5)}) {
    final idx = _inbox.indexWhere(test);
    if (idx != -1) return Future.value(_inbox.removeAt(idx));
    final w = _Waiter(test);
    _waiters.add(w);
    return w.completer.future.timeout(timeout, onTimeout: () {
      _waiters.remove(w);
      throw TimeoutException('No matching SIP message within $timeout');
    });
  }

  Future<SipMessage> request(String method, {Duration? timeout}) =>
      next((m) => m.method == method,
          timeout: timeout ?? const Duration(seconds: 5));

  Future<SipMessage> response(int code, {String? method, Duration? timeout}) =>
      next(
          (m) =>
              m.statusCode == code && (method == null || m.cseqMethod == method),
          timeout: timeout ?? const Duration(seconds: 5));

  /// Fails when a message matching [test] arrives within [within].
  Future<void> expectNothing(bool Function(SipMessage m) test,
      {Duration within = const Duration(milliseconds: 700)}) async {
    try {
      final m = await next(test, timeout: within);
      throw StateError('Unexpected message: ${m.startLine}');
    } on TimeoutException {
      return;
    }
  }

  /// Drop everything received so far that nobody waited for.
  void clearInbox() => _inbox.clear();

  void send(String raw) {
    _sender.send(utf8.encode(raw), clientAddress!, clientPort!);
  }

  /// Build a response to [req].
  String respond(SipMessage req, int code, String reason,
      {String? toTag, List<String> headers = const [], String? body}) {
    final b = StringBuffer('SIP/2.0 $code $reason\r\n');
    for (final v in req.headerAll('Via')) {
      b.write('Via: $v\r\n');
    }
    b.write('From: ${req.from}\r\n');
    final to = req.to ?? '';
    b.write(toTag != null && extractTag(to) == null
        ? 'To: $to;tag=$toTag\r\n'
        : 'To: $to\r\n');
    b.write('Call-ID: ${req.callId}\r\n');
    b.write('CSeq: ${req.header('CSeq')}\r\n');
    for (final h in headers) {
      b.write('$h\r\n');
    }
    _body(b, body);
    return b.toString();
  }

  /// Build a request from the server to the client.
  String requestTo(String method,
      {required String callId,
      required int cseq,
      required String from,
      required String to,
      String? branch,
      List<String> headers = const [],
      String? body,
      String? contentType}) {
    final b = StringBuffer(
        '$method sip:1001@127.0.0.1:$clientPort SIP/2.0\r\n');
    b.write('Via: SIP/2.0/UDP 127.0.0.1:$port;rport;branch=${branch ?? 'z9hG4bK$method$cseq${callId.hashCode}'}\r\n');
    b.write('Max-Forwards: 70\r\n');
    b.write('From: $from\r\n');
    b.write('To: $to\r\n');
    b.write('Call-ID: $callId\r\n');
    b.write('CSeq: $cseq $method\r\n');
    b.write('Contact: <sip:2000@127.0.0.1:$port>\r\n');
    for (final h in headers) {
      b.write('$h\r\n');
    }
    _body(b, body, contentType: contentType);
    return b.toString();
  }

  void _body(StringBuffer b, String? body, {String? contentType}) {
    if (body == null) {
      b.write('Content-Length: 0\r\n\r\n');
      return;
    }
    b.write('Content-Type: ${contentType ?? 'application/sdp'}\r\n');
    b.write('Content-Length: ${utf8.encode(body).length}\r\n\r\n');
    b.write(body);
  }

  void close() => socket.close();
}

class _Waiter {
  final bool Function(SipMessage m) test;
  final Completer<SipMessage> completer = Completer();
  _Waiter(this.test);
}

/// SDP the fake server offers or answers with.
String pbxSdp(
    {int port = 30000,
    String payloads = '8 0 101',
    String direction = 'sendrecv',
    String host = '127.0.0.1'}) {
  final pts = payloads.split(' ').map(int.parse);
  return [
    'v=0',
    'o=- 100 100 IN IP4 $host',
    's=Asterisk',
    'c=IN IP4 $host',
    't=0 0',
    'm=audio $port RTP/AVP $payloads',
    for (final p in pts)
      if (p == 8)
        'a=rtpmap:8 PCMA/8000'
      else if (p == 0)
        'a=rtpmap:0 PCMU/8000'
      else if (p >= 96)
        'a=rtpmap:$p telephone-event/8000',
    'a=$direction',
    '',
  ].join('\r\n');
}

/// Media handler that records what the SIP client asked for.
class FakeMedia implements SipMediaHandler {
  int prepares = 0;
  int micStarts = 0;
  int micStops = 0;
  int silences = 0;
  int releases = 0;
  final List<String> remotes = [];
  final List<String> dtmf = [];
  Set<String> ignored = {};
  bool open = false;
  bool micResult = true;

  @override
  Future<int?> prepare() async {
    prepares++;
    open = true;
    return 40000;
  }

  @override
  int? get localPort => open ? 40000 : null;

  @override
  void setRemote(String host, int port,
      {required int payloadType, int? dtmfPayloadType}) {
    remotes.add('$host:$port/$payloadType/${dtmfPayloadType ?? '-'}');
  }

  @override
  void setIgnoredEndpoints(Set<String> endpoints) => ignored = endpoints;

  @override
  Future<bool> startMicrophone() async {
    micStarts++;
    return micResult;
  }

  @override
  void stopMicrophone() => micStops++;

  @override
  void sendSilence() => silences++;

  @override
  Future<void> sendDtmf(String digit, {int durationMs = 160}) async =>
      dtmf.add(digit);

  @override
  void release() {
    releases++;
    open = false;
  }
}

/// Poll [condition] until it holds or [timeout] passes.
Future<void> eventually(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
