import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../logging.dart';
import '../net/datagram_sender.dart';
import 'sdp.dart';
import 'sip_auth.dart';
import 'sip_call.dart';
import 'sip_call_event.dart';
import 'sip_media.dart';
import 'sip_message.dart';

/// An incoming INVITE that has not been answered yet.
class _PendingInvite {
  final SipMessage request;
  final String localTag;
  final String number;
  final String? name;
  String? lastProvisional;
  Timer? ttl;

  _PendingInvite(this.request, this.localTag, this.number, this.name);
}

/// A request we sent and retransmit until a response arrives (RFC 3261 17.1).
class _ClientTransaction {
  final String key;
  final String message;
  final bool isInvite;
  final void Function()? onTimeout;
  Timer? timer;
  Duration interval;
  Duration elapsed = Duration.zero;

  _ClientTransaction(this.key, this.message, this.isInvite, this.onTimeout,
      this.interval);
}

/// A 2xx to an INVITE that we retransmit until the ACK arrives (17.2.1).
class _OkRetransmit {
  final String message;
  final bool initial;
  Timer? timer;
  Duration interval;
  Duration elapsed = Duration.zero;

  _OkRetransmit(this.message, this.initial, this.interval);
}

enum _ReinviteKind { hold, unhold }

/// Our own hold or resume re-INVITE in flight.
class _PendingReinvite {
  final _ReinviteKind kind;
  final Completer<bool> completer;
  int cseq = 0;
  String? sdp;
  bool authAttempted = false;
  bool glareRetried = false;

  _PendingReinvite(this.kind, [Completer<bool>? completer])
      : completer = completer ?? Completer<bool>();

  void finish(bool ok) {
    if (!completer.isCompleted) completer.complete(ok);
  }
}

/// A non-INVITE in-dialog request (BYE, REFER, INFO) kept for a 401 retry.
class _InDialogRequest {
  final List<String> extraHeaders;
  final String? body;
  final String? contentType;
  int cseq = 0;
  bool authAttempted = false;

  _InDialogRequest(this.extraHeaders, this.body, this.contentType);
}

/// Protocol state of one call.
class _Dialog {
  final SipCall call;

  /// Request-URI of our initial INVITE (CANCEL and non-2xx ACK reuse it).
  String? inviteRequestUri;
  bool provisionalReceived = false;
  bool ringingNotified = false;
  bool inviteAuthAttempted = false;
  final Set<int> authHandledCseqs = {};

  /// Ended locally, still finishing BYE / CANCEL on the wire.
  bool terminating = false;
  bool cancelRequested = false;
  bool cancelSent = false;
  Timer? cancelTimer;

  _PendingReinvite? reinvite;
  final Map<String, _InDialogRequest> requests = {};

  bool transferring = false;
  Completer<bool>? transferAccepted;
  Timer? transferTimer;

  /// Incoming calls: CSeq of the initial INVITE and our 200 OK to it, so a
  /// retransmitted INVITE gets the same answer again.
  int? initialRemoteCseq;
  String? initialOk;

  /// Last re-INVITE from the remote and our answer, for retransmissions.
  int? lastRemoteReinviteCseq;
  String? lastReinviteOk;

  _Dialog(this.call);

  void cancelTimers() {
    cancelTimer?.cancel();
    transferTimer?.cancel();
  }
}

/// SIP user agent over UDP.
///
/// Handles registration (with digest auth, refresh and un-REGISTER),
/// incoming and outgoing calls, hold and resume, remote hold, blind transfer,
/// DTMF and several calls at once. Audio is delegated to a
/// [SipMediaHandler].
class UdpSipClient {
  RawDatagramSocket? _socket;
  DatagramSender? _sender;
  final String _server;
  final int _port;
  final String _username;
  final String _password;
  final String _displayName;
  final String _authUsername;
  final String? _forcedLocalIp;
  final int _bindPort;

  /// Value of the User-Agent header (also used as the SDP session name).
  final String userAgent;

  /// How often an empty keep-alive is sent to the server to hold the NAT
  /// binding open, so incoming calls keep reaching us. Zero disables it.
  final Duration keepAliveInterval;

  /// Use the address the server sees us at (`received` and `rport` on the
  /// Via of the REGISTER response) in Contact, Via and SDP, and register
  /// again with it. Same as "Allow IP rewrite" in MicroSIP (pjsua
  /// `allow_contact_rewrite`). Needed behind NAT when the server does not
  /// fix contacts itself, otherwise incoming calls never arrive.
  final bool allowContactRewrite;

  /// The audio side. When null, calls are signalled without audio (tests).
  SipMediaHandler? media;

  int _requestedExpires;

  InternetAddress? _serverAddress;
  int? _localPort;
  String? _localIp;

  // Registration dialog.
  String? _regCallId;
  String? _regTag;
  int _regCseq = 0;
  DigestChallenge? _regChallenge;
  int? _regAuthCseq;
  bool _regUsedCachedNonce = false;
  Timer? _refreshTimer;
  Timer? _keepAliveTimer;
  Timer? _retryTimer;
  int _retryAttempt = 0;
  String? _publicAddress;
  String? _publicHost;
  int? _publicPort;

  /// Address used in Contact, Via and SDP after a rewrite (null: local).
  String? _contactHost;
  int? _contactPort;
  int _rewritesInARow = 0;

  bool _unregistering = false;
  Completer<void>? _unregisterCompleter;
  bool _closing = false;
  bool _closed = false;
  bool _isRegistered = false;

  final Map<String, _Dialog> _dialogs = {};
  final Map<String, _PendingInvite> _pendingInvites = {};
  final Map<String, String> _rejected = {};
  final Map<String, _ClientTransaction> _transactions = {};
  final Map<String, _OkRetransmit> _okRetransmits = {};
  final Set<String> _terminalNotified = {};
  final Set<Timer> _miscTimers = {};

  /// The call that currently drives the microphone and RTP focus. With
  /// several calls the socket and microphone are shared, so teardown has to
  /// check ownership instead of blindly releasing audio.
  String? _audioOwnerCallId;

  static const Duration _t1 = Duration(milliseconds: 500);
  static const Duration _t2 = Duration(seconds: 4);
  static const Duration _txTimeout = Duration(seconds: 32);
  static const Duration _pendingInviteTtl = Duration(seconds: 120);
  /// RFC 5626 double-CRLF keep-alive.
  static const String _keepAlivePing = '\r\n\r\n';
  static const String _allow =
      'INVITE, ACK, CANCEL, BYE, NOTIFY, REFER, OPTIONS, INFO';

  static final Random _rng = Random.secure();

  bool get isRegistered => _isRegistered;

  /// Local SIP port, null before [connect].
  int? get localSipPort => _localPort;

  /// Local IP address used in Via, Contact and SDP.
  String? get localIp => _localIp;

  /// The address and port the server sees us at (from `received`/`rport`
  /// in the REGISTER response). Differs from [localIp] behind NAT.
  String? get publicAddress => _publicAddress;

  /// Calls that are established, ringing out or on hold.
  Map<String, SipCall> get activeCalls => Map.unmodifiable({
        for (final e in _dialogs.entries)
          if (!e.value.terminating) e.key: e.value.call,
      });

  /// Call-IDs of incoming calls still ringing.
  List<String> get ringingCallIds => _pendingInvites.keys.toList();

  /// Fires when registration state flips.
  void Function(bool registered)? onRegistrationStateChanged;

  /// Fires when a new incoming call starts ringing.
  void Function(String callerNumber, String? callerName, String callId)?
      onIncomingCall;

  /// Fires on every call state change.
  void Function(String callId, SipCallEvent event)? onCallStateChanged;

  /// Fires on errors worth showing to the user.
  void Function(String error)? onError;

  UdpSipClient({
    required String server,
    required int port,
    required String username,
    required String password,
    String? displayName,
    String? authUsername,
    this.media,
    int expires = 600,
    this.userAgent = 'IQ-SIP',
    this.keepAliveInterval = const Duration(seconds: 25),
    int localPort = 0,
    String? localIp,
    this.allowContactRewrite = false,
  })  : _server = server,
        _port = port,
        _username = username,
        _password = password,
        _displayName = (displayName != null && displayName.isNotEmpty)
            ? displayName
            : username,
        _authUsername = (authUsername != null && authUsername.isNotEmpty)
            ? authUsername
            : username,
        _requestedExpires = expires,
        _bindPort = localPort,
        _forcedLocalIp = localIp;

  // ── Connect / registration ─────────────────────────────────

  /// Bind the socket and REGISTER. Calling it again while connected only
  /// retries the registration on the same socket.
  Future<void> connect() async {
    if (_socket != null && !_closed) {
      if (_isRegistered) return;
      _register();
      return;
    }
    try {
      final addresses = await InternetAddress.lookup(_server,
          type: InternetAddressType.IPv4);
      if (addresses.isEmpty) throw SocketException('Cannot resolve $_server');
      _serverAddress = addresses.first;
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _bindPort);
      _sender = DatagramSender(_socket!);
      _localPort = _socket!.port;
      _localIp = _forcedLocalIp ?? await _detectLocalIp();

      sipLog('[SIP] Local IP: $_localIp, SIP port: $_localPort');
      sipLog('[SIP] Server: $_server:$_port (${_serverAddress!.address})');

      // Every connect starts a fresh registration dialog.
      _regCallId = _newCallId();
      _regTag = _newTag();
      _regCseq = 0;
      _regChallenge = null;
      _regAuthCseq = null;
      _closing = false;
      _closed = false;
      _unregistering = false;
      _unregisterCompleter = null;
      _isRegistered = false;
      _retryAttempt = 0;
      _publicAddress = null;
      _publicHost = null;
      _publicPort = null;
      _contactHost = null;
      _contactPort = null;
      _rewritesInARow = 0;

      _socket!.listen(
        _onSocketEvent,
        onError: (Object e) => sipLog('[SIP] Socket error: $e'),
      );

      _register();
    } catch (e) {
      onError?.call('Connection failed: $e');
      rethrow;
    }
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.closed) {
      if (!_closed) {
        sipLog('[SIP] Socket closed by the system');
        onError?.call('SIP socket closed, reconnect to register again');
        disconnect();
      }
      return;
    }
    if (event == RawSocketEvent.write) {
      _sender?.onWrite();
      return;
    }
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    Datagram? d;
    while ((d = socket.receive()) != null) {
      _handleIncoming(utf8.decode(d!.data, allowMalformed: true));
    }
  }

  String get _registrar =>
      _port == 5060 ? 'sip:$_server' : 'sip:$_server:$_port';
  String get _aor => 'sip:$_username@$_server';
  /// Host and port we advertise: the public ones after a contact rewrite.
  String get _sentByHost => _contactHost ?? _localIp ?? '0.0.0.0';
  int? get _sentByPort => _contactPort ?? _localPort;
  String get _contact => '<sip:$_username@$_sentByHost:$_sentByPort>';
  String get _localIdentity => '${quoteDisplayName(_displayName)} <$_aor>';

  void _register({bool withAuth = false}) {
    if (_socket == null) return;
    _regCseq++;
    final branch = _newBranch();
    final challenge = withAuth ? _regChallenge : null;
    final expires = _unregistering ? 0 : _requestedExpires;

    final b = StringBuffer();
    _w(b, 'REGISTER $_registrar SIP/2.0');
    _w(b, _via(branch));
    _w(b, 'Max-Forwards: 70');
    _w(b, 'From: $_localIdentity;tag=$_regTag');
    _w(b, 'To: <$_aor>');
    _w(b, 'Call-ID: $_regCallId');
    _w(b, 'CSeq: $_regCseq REGISTER');
    _w(b, 'Contact: $_contact');
    _w(b, 'Expires: $expires');
    _w(b, 'Allow: $_allow');
    _w(b, 'User-Agent: $userAgent');
    if (challenge != null) {
      _regAuthCseq = _regCseq;
      _w(b,
          '${challenge.responseHeaderName}: ${challenge.authorize(method: 'REGISTER', uri: _registrar, username: _authUsername, password: _password)}');
    }
    _w(b, 'Content-Length: 0');
    _blank(b);

    _startTransaction(branch, 'REGISTER', b.toString(),
        onTimeout: _onRegisterTimeout);
  }

  void _onRegisterResponse(SipMessage res, int code) {
    if (res.cseqNumber != _regCseq) return; // answer to an older attempt
    if (code < 200) return;
    _learnPublicAddress(res);

    if (code == 401 || code == 407) {
      final challenge = DigestChallenge.pick(
          res.headerAll(code == 407 ? 'Proxy-Authenticate' : 'WWW-Authenticate'),
          isProxy: code == 407);
      final hadAuth = _regAuthCseq == res.cseqNumber;
      if (challenge == null ||
          (hadAuth && !_regUsedCachedNonce && !challenge.stale)) {
        _registrationFailed(challenge == null
            ? 'Registration failed: unsupported authentication'
            : 'Registration failed: authentication rejected, check username and password');
        return;
      }
      _regChallenge = challenge;
      _regUsedCachedNonce = false;
      _register(withAuth: true);
      return;
    }

    if (code >= 200 && code < 300) {
      if (_unregistering) {
        sipLog('[SIP] Un-REGISTER acknowledged for $_username@$_server');
        _completeUnregister();
        return;
      }
      final granted = _grantedExpires(res);
      sipLog('[SIP] Registered as $_username@$_server (expires $granted s)');
      _retryAttempt = 0;
      _setRegistered(true);
      _startKeepAlive();
      if (_rewriteContactIfNeeded()) return;
      _scheduleRefresh(granted);
      return;
    }

    if (code == 423) {
      final min = int.tryParse(res.header('Min-Expires') ?? '');
      if (min != null && min > _requestedExpires) {
        _requestedExpires = min;
        _regUsedCachedNonce = _regChallenge != null;
        _register(withAuth: _regChallenge != null);
        return;
      }
    }

    _registrationFailed('Registration failed: $code ${res.reasonPhrase}');
  }

  void _onRegisterTimeout() {
    _registrationFailed(
        'Registration timed out, no answer from $_server:$_port');
  }

  void _registrationFailed(String message) {
    if (_unregistering) {
      _completeUnregister();
      return;
    }
    sipLog('[SIP] $message');
    _setRegistered(false);
    onError?.call(message);
    _scheduleRetry();
  }

  int _grantedExpires(SipMessage res) {
    final mine = '$_sentByHost:$_sentByPort';
    for (final c in res.headerValues('Contact')) {
      if (c.contains(mine)) {
        final e = int.tryParse(headerParam(c, 'expires') ?? '');
        if (e != null) return e;
      }
    }
    return int.tryParse(res.header('Expires') ?? '') ?? _requestedExpires;
  }

  void _learnPublicAddress(SipMessage res) {
    final via = res.topVia;
    if (via == null) return;
    final received = headerParam(via, 'received');
    final rport = headerParam(via, 'rport');
    if (received == null || received.isEmpty) return;
    final port = int.tryParse(rport ?? '') ?? _sentByPort;
    final addr = '$received:$port';
    _publicHost = received;
    _publicPort = port;
    if (addr != _publicAddress) {
      _publicAddress = addr;
      if (received != _localIp) {
        sipLog('[SIP] Behind NAT, the server sees us as $addr');
      }
    }
  }

  /// With [allowContactRewrite], register again with the public address
  /// when it differs from the one we advertise. Returns true when a new
  /// REGISTER went out.
  bool _rewriteContactIfNeeded() {
    if (!allowContactRewrite) return false;
    final host = _publicHost;
    final port = _publicPort;
    if (host == null || port == null) return false;
    if (host == _sentByHost && port == _sentByPort) {
      _rewritesInARow = 0;
      return false;
    }
    // A server that reports a different address every time must not keep
    // us re-registering in a loop.
    if (_rewritesInARow >= 2) return false;
    _rewritesInARow++;
    sipLog('[SIP] Contact rewrite: $_sentByHost:$_sentByPort -> '
        '$host:$port, registering again');
    _contactHost = host;
    _contactPort = port;
    _regUsedCachedNonce = _regChallenge != null;
    _register(withAuth: _regChallenge != null);
    return true;
  }

  void _setRegistered(bool value) {
    if (_isRegistered == value) return;
    _isRegistered = value;
    onRegistrationStateChanged?.call(value);
  }

  void _scheduleRefresh(int granted) {
    _refreshTimer?.cancel();
    final seconds = max(5, max(granted ~/ 2, granted - 60));
    _refreshTimer = Timer(Duration(seconds: seconds), () {
      if (_closed || _closing || _unregistering) return;
      _regUsedCachedNonce = _regChallenge != null;
      _register(withAuth: _regChallenge != null);
    });
  }

  void _scheduleRetry() {
    if (_closed || _closing || _socket == null) return;
    _retryTimer?.cancel();
    final seconds = min(300, 30 * (1 << min(_retryAttempt, 4)));
    _retryAttempt++;
    sipLog('[SIP] Retrying registration in $seconds s');
    _retryTimer = Timer(Duration(seconds: seconds), () {
      if (_closed || _closing) return;
      _register();
    });
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    if (keepAliveInterval <= Duration.zero) return;
    _keepAliveTimer = Timer.periodic(keepAliveInterval, (_) {
      final a = _serverAddress;
      if (_sender == null || a == null || !_isRegistered) return;
      _sender!.send(utf8.encode(_keepAlivePing), a, _port);
    });
  }

  // ── Message dispatch ───────────────────────────────────────

  void _handleIncoming(String text) {
    final msg = SipMessage.parse(text);
    if (msg == null) return; // keep-alive pong or junk
    _trace('<<<', text, msg.startLine);
    final Future<void> f =
        msg.isResponse ? _handleResponse(msg) : _handleRequest(msg);
    f.catchError((Object e, StackTrace st) {
      sipLog('[SIP] Error handling ${msg.startLine}: $e\n$st');
      onError?.call('Error handling SIP message: $e');
    });
  }

  Future<void> _handleResponse(SipMessage res) async {
    final code = res.statusCode ?? 0;
    final method = res.cseqMethod;
    final via = res.topVia;
    final branch = via == null ? null : headerParam(via, 'branch');
    if (branch != null && method != null) {
      _transactionResponse('$branch:$method', code);
    }
    switch (method) {
      case 'REGISTER':
        _onRegisterResponse(res, code);
      case 'INVITE':
        await _onInviteResponse(res, code);
      case 'BYE':
      case 'REFER':
      case 'INFO':
        _onInDialogResponse(res, code, method!);
      default:
        break;
    }
  }

  Future<void> _handleRequest(SipMessage req) async {
    switch (req.method) {
      case 'INVITE':
        await _onInvite(req);
      case 'ACK':
        _onAck(req);
      case 'BYE':
        _onBye(req);
      case 'CANCEL':
        _onCancel(req);
      case 'OPTIONS':
        _respond(req, 200, 'OK', extraHeaders: [
          'Allow: $_allow',
          'Accept: application/sdp',
        ]);
      case 'NOTIFY':
        _respond(req, 200, 'OK');
        _onNotify(req);
      case 'INFO':
        _respond(req, 200, 'OK');
      default:
        _respond(req, 501, 'Not Implemented', extraHeaders: ['Allow: $_allow']);
    }
  }

  // ── Incoming calls ─────────────────────────────────────────

  Future<void> _onInvite(SipMessage req) async {
    final callId = req.callId;
    if (callId == null) return;
    final cseq = req.cseqNumber ?? 0;

    final pending = _pendingInvites[callId];
    if (pending != null) {
      // Retransmitted INVITE while ringing: repeat the last provisional.
      if (pending.lastProvisional != null) _send(pending.lastProvisional!);
      return;
    }
    final rejected = _rejected[callId];
    if (rejected != null) {
      _send(rejected);
      return;
    }

    final d = _dialogs[callId];
    if (d != null) {
      if (d.call.isIncoming && d.initialRemoteCseq == cseq) {
        if (d.initialOk != null) _send(d.initialOk!);
        return;
      }
      if (d.lastRemoteReinviteCseq == cseq) {
        if (d.lastReinviteOk != null) _send(d.lastReinviteOk!);
        return;
      }
      if (d.terminating) {
        _respond(req, 481, 'Call/Transaction Does Not Exist');
        return;
      }
      if (d.reinvite != null || !d.call.isConfirmed) {
        // Glare: both sides sent a re-INVITE (RFC 3261 14.2).
        _respond(req, 491, 'Request Pending');
        return;
      }
      _onReinvite(d, req);
      return;
    }

    if (extractTag(req.to ?? '') != null) {
      _respond(req, 481, 'Call/Transaction Does Not Exist');
      return;
    }
    if (_closing || _closed) {
      _respond(req, 480, 'Temporarily Unavailable');
      return;
    }
    if (req.hasSdp && SdpInfo.parse(req.body).chooseCodec() == null) {
      _rememberRejected(
          callId, _respond(req, 488, 'Not Acceptable Here', toTag: _newTag()));
      return;
    }

    final from = req.from ?? '';
    final number = extractUser(from) ?? from;
    var name = extractDisplayName(from);
    if (name == number) name = null;
    final localTag = _newTag();

    _respond(req, 100, 'Trying');
    final ringing = _buildResponse(req, 180, 'Ringing',
        toTag: localTag, withContact: true, extraHeaders: ['Allow: $_allow']);
    final p = _PendingInvite(req, localTag, number, name)
      ..lastProvisional = ringing;
    p.ttl = Timer(_pendingInviteTtl, () {
      if (_pendingInvites.remove(callId) == null) return;
      sipLog('[SIP] Unanswered call $callId timed out');
      _rememberRejected(callId,
          _respond(req, 480, 'Temporarily Unavailable', toTag: localTag));
      _emit(callId, SipCallEvent.cancelled);
    });
    _pendingInvites[callId] = p;
    _send(ringing);
    onIncomingCall?.call(number, name, callId);
  }

  /// Answer a ringing incoming call.
  Future<void> answerCall(String callId) async {
    final p = _pendingInvites[callId];
    if (p == null) {
      if (_dialogs.containsKey(callId)) return; // already answered
      onError?.call('No pending invite for callId: $callId');
      _emit(callId, SipCallEvent.failed);
      return;
    }

    final req = p.request;
    final offer = req.hasSdp ? SdpInfo.parse(req.body) : null;
    final codec = offer?.chooseCodec();

    final rtpPort = await media?.prepare();
    if (!_pendingInvites.containsKey(callId)) return; // cancelled meanwhile
    _removePending(callId);
    if (media != null && rtpPort == null) {
      _rememberRejected(callId,
          _respond(req, 500, 'Server Internal Error', toTag: p.localTag));
      onError?.call('Failed to answer call: RTP socket could not be opened');
      _emit(callId, SipCallEvent.failed);
      return;
    }

    final from = req.from ?? '';
    final contact = req.header('Contact');
    final call = SipCall(
      callId: callId,
      fromHeader: stripTag(from),
      toHeader: stripTag(req.to ?? ''),
      contact: contact,
      localTag: p.localTag,
      remoteTag: extractTag(from),
      isIncoming: true,
      remoteNumber: p.number,
      remoteName: p.name,
    )
      ..remoteTarget = contact != null ? extractUri(contact) : null
      ..routeSet = req.headerValues('Record-Route');

    var direction = MediaDirection.sendrecv;
    if (offer != null && codec != null) {
      call.payloadType = codec;
      call.dtmfPayloadType = offer.telephoneEvent;
      if (offer.endpoint != null && offer.host != '0.0.0.0') {
        call.remoteRtpHost = offer.host;
        call.remoteRtpPort = offer.port;
      }
      call.isRemoteHold = offer.isHold;
      direction = offer.direction.answerFor();
    } else {
      // Delayed offer: we offer in the 200 OK, the answer comes in the ACK.
      call.answerExpectedInAck = true;
    }

    final d = _Dialog(call)..initialRemoteCseq = req.cseqNumber;
    _dialogs[callId] = d;

    final sdp = offer == null
        ? _sdpFor(call)
        : _sdpFor(call,
            direction: direction, codec: codec, dtmf: offer.telephoneEvent);
    final ok = _buildResponse(req, 200, 'OK',
        toTag: p.localTag,
        withContact: true,
        extraHeaders: ['Allow: $_allow'],
        body: sdp);
    d.initialOk = ok;
    _send(ok);
    _startOkRetransmit(callId, req.cseqNumber ?? 0, ok, initial: true);
    sipLog('[SIP] Answered $callId, remote RTP ${call.remoteRtp}');

    _audioOwnerCallId = callId;
    _focusAudio(call);
    _refreshOtherLegs();
    media?.sendSilence();
    if (!call.isRemoteHold) await _startMicrophone();
  }

  void _onAck(SipMessage req) {
    final callId = req.callId;
    if (callId == null) return;
    final d = _dialogs[callId];
    if (d == null) return;
    final cseq = req.cseqNumber ?? 0;
    _stopOkRetransmit(callId, cseq);
    final call = d.call;
    if (call.answerExpectedInAck && req.hasSdp) {
      call.answerExpectedInAck = false;
      _applyRemoteSdp(d, req.body, isAnswer: true);
    }
    if (call.isIncoming && cseq == d.initialRemoteCseq && !call.isConfirmed) {
      call.isConfirmed = true;
      _emit(callId, SipCallEvent.confirmed);
    }
  }

  void _onReinvite(_Dialog d, SipMessage req) {
    final call = d.call;
    final callId = call.callId;
    final cseq = req.cseqNumber ?? 0;

    SdpInfo? offer;
    int? codec;
    if (req.hasSdp) {
      offer = SdpInfo.parse(req.body);
      codec = offer.chooseCodec();
      if (codec == null) {
        _respond(req, 488, 'Not Acceptable Here');
        return;
      }
    }

    final owns = _audioOwnerCallId == null || _audioOwnerCallId == callId;
    String sdp;
    bool? remoteHoldNow;
    if (offer != null) {
      remoteHoldNow = offer.isHold;
      var direction = offer.direction.answerFor(localHold: call.isOnHold);
      if (offer.host == '0.0.0.0') {
        direction =
            call.isOnHold ? MediaDirection.inactive : MediaDirection.recvonly;
      }
      call.payloadType = codec!;
      call.dtmfPayloadType = offer.telephoneEvent;
      if (offer.endpoint != null && offer.host != '0.0.0.0') {
        call.remoteRtpHost = offer.host;
        call.remoteRtpPort = offer.port;
        // Only the call that owns the audio may move the shared RTP focus,
        // a refresh on a held call must not steal the live conversation.
        if (owns && !call.isOnHold) _focusAudio(call);
      }
      _refreshOtherLegs();
      sdp = _sdpFor(call,
          direction: direction, codec: codec, dtmf: offer.telephoneEvent);
    } else {
      // Re-INVITE without SDP (Asterisk sends these around transfers): we
      // offer here and the answer arrives in the ACK.
      call.answerExpectedInAck = true;
      sdp = _sdpFor(call,
          direction:
              call.isOnHold ? MediaDirection.sendonly : MediaDirection.sendrecv);
    }

    final ok = _buildResponse(req, 200, 'OK',
        withContact: true, extraHeaders: ['Allow: $_allow'], body: sdp);
    d.lastRemoteReinviteCseq = cseq;
    d.lastReinviteOk = ok;
    _send(ok);
    _startOkRetransmit(callId, cseq, ok);

    if (remoteHoldNow == null) return;
    if (remoteHoldNow && !call.isRemoteHold) {
      call.isRemoteHold = true;
      if (owns) media?.stopMicrophone();
      sipLog('[SIP] Remote hold on $callId');
      _emit(callId, SipCallEvent.remoteHeld);
    } else if (!remoteHoldNow && call.isRemoteHold) {
      call.isRemoteHold = false;
      if (owns && !call.isOnHold) {
        _audioOwnerCallId = callId;
        _startMicrophone();
      }
      sipLog('[SIP] Remote resumed $callId');
      _emit(callId, SipCallEvent.remoteResumed);
    }
  }

  void _onBye(SipMessage req) {
    final callId = req.callId;
    if (callId == null) return;
    final d = _dialogs[callId];
    if (d == null) {
      final p = _pendingInvites[callId];
      if (p != null) {
        _respond(req, 200, 'OK');
        _rememberRejected(callId,
            _respond(p.request, 487, 'Request Terminated', toTag: p.localTag));
        _removePending(callId);
        _emit(callId, SipCallEvent.cancelled);
        return;
      }
      if (_terminalNotified.contains(callId)) {
        _respond(req, 200, 'OK');
      } else {
        _respond(req, 481, 'Call/Transaction Does Not Exist');
      }
      return;
    }
    _respond(req, 200, 'OK');
    if (d.terminating) {
      _finishDialog(callId);
      return;
    }
    if (d.transferring) {
      // The server hung up our leg after taking the transfer over.
      d.transferring = false;
      _emit(callId, SipCallEvent.transferred);
    }
    _endDialog(callId, SipCallEvent.ended);
  }

  void _onCancel(SipMessage req) {
    final callId = req.callId;
    if (callId == null) return;
    final p = _pendingInvites[callId];
    _respond(req, 200, 'OK', toTag: p?.localTag);
    if (p == null) return; // CANCEL after answer has no effect (9.2)
    _rememberRejected(callId,
        _respond(p.request, 487, 'Request Terminated', toTag: p.localTag));
    _removePending(callId);
    _emit(callId, SipCallEvent.cancelled);
  }

  void _onNotify(SipMessage req) {
    final callId = req.callId;
    if (callId == null) return;
    final d = _dialogs[callId];
    if (d == null || !d.transferring) return;
    final event = (req.header('Event') ?? '').toLowerCase();
    if (!event.startsWith('refer')) return;
    final frag = req.body
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('SIP/2.0'), orElse: () => '');
    final code = int.tryParse(frag.split(' ').elementAtOrNull(1) ?? '');
    if (code == null || code < 200) return; // still trying
    d.transferring = false;
    d.transferTimer?.cancel();
    if (code < 300) {
      sipLog('[SIP] Transfer of $callId completed ($frag)');
      _emit(callId, SipCallEvent.transferred);
      hangupCall(callId);
    } else {
      sipLog('[SIP] Transfer of $callId failed ($frag)');
      onError?.call('Transfer failed: ${frag.substring(min(8, frag.length)).trim()}');
    }
  }

  // ── Outgoing calls ─────────────────────────────────────────

  /// Call [destination] (an extension, a number or a full `sip:` URI).
  /// Returns the Call-ID of the new call.
  Future<String> makeCall(String destination) async {
    if (!_isRegistered) throw StateError('Not registered');
    final target = _targetUri(destination);
    final rtpPort = await media?.prepare();
    if (media != null && rtpPort == null) {
      final msg = 'Failed to make call: RTP socket could not be opened';
      onError?.call(msg);
      throw StateError(msg);
    }

    final callId = _newCallId();
    final call = SipCall(
      callId: callId,
      fromHeader: _localIdentity,
      toHeader: '<$target>',
      localTag: _newTag(),
      isIncoming: false,
      dialogCseq: 0,
      remoteNumber: extractUser(target) ?? destination,
    )..remoteTarget = target;
    final d = _Dialog(call)..inviteRequestUri = target;
    _dialogs[callId] = d;
    _sendInitialInvite(d);
    _emit(callId, SipCallEvent.calling);
    return callId;
  }

  void _sendInitialInvite(_Dialog d, {DigestChallenge? challenge}) {
    final call = d.call;
    call.dialogCseq++;
    call.inviteCSeq = call.dialogCseq;
    final branch = _newBranch();
    call.inviteBranch = branch;
    final uri = d.inviteRequestUri!;
    final sdp = challenge == null
        ? _sdpFor(call)
        : _sdpFor(call, bumpVersion: false);
    final body = utf8.encode(sdp);

    final b = StringBuffer();
    _w(b, 'INVITE $uri SIP/2.0');
    _w(b, _via(branch));
    _w(b, 'Max-Forwards: 70');
    _w(b, 'From: ${call.fromHeader};tag=${call.localTag}');
    _w(b, 'To: ${call.toHeader}');
    _w(b, 'Call-ID: ${call.callId}');
    _w(b, 'CSeq: ${call.inviteCSeq} INVITE');
    _w(b, 'Contact: $_contact');
    _w(b, 'Allow: $_allow');
    _w(b, 'User-Agent: $userAgent');
    if (challenge != null) {
      _w(b,
          '${challenge.responseHeaderName}: ${challenge.authorize(method: 'INVITE', uri: uri, username: _authUsername, password: _password)}');
    }
    _w(b, 'Content-Type: application/sdp');
    _w(b, 'Content-Length: ${body.length}');
    _blank(b);
    b.write(sdp);

    final callId = call.callId;
    _startTransaction(branch, 'INVITE', b.toString(),
        onTimeout: () => _onInviteTimeout(callId));
  }

  void _onInviteTimeout(String callId) {
    final d = _dialogs[callId];
    if (d == null || d.call.isConfirmed) return;
    if (d.terminating) {
      _finishDialog(callId);
      return;
    }
    onError?.call('Call failed: no answer from $_server');
    _endDialog(callId, SipCallEvent.failed);
  }

  Future<void> _onInviteResponse(SipMessage res, int code) async {
    final callId = res.callId;
    if (callId == null) return;
    final d = _dialogs[callId];
    final cseq = res.cseqNumber ?? 0;
    if (d == null) {
      // Late response for a call we no longer track. A 2xx still has to be
      // ACKed and hung up, or the far end sits on a dead line.
      if (code >= 200 && code < 300) {
        _orphanAckAndBye(res);
      } else if (code >= 300) {
        _sendNon2xxAck(res, extractUri(res.to ?? '') ?? _registrar, const []);
      }
      return;
    }
    final call = d.call;
    final reinvite = d.reinvite;
    final isReinvite = reinvite != null && cseq == reinvite.cseq;

    if (code < 200) {
      if (!isReinvite && cseq == call.inviteCSeq) _onProvisional(d, res, code);
      return;
    }
    if (code < 300) {
      await _onInvite2xx(d, res, isReinvite);
      return;
    }

    // Final failure: always ACK (17.1.1.3).
    if (isReinvite || call.isConfirmed) {
      _sendNon2xxAck(res, call.remoteTarget ?? d.inviteRequestUri ?? _registrar,
          call.routeSet);
    } else {
      _sendNon2xxAck(res, d.inviteRequestUri ?? _registrar, const []);
    }

    if (d.authHandledCseqs.contains(cseq)) return; // retransmission
    if (code == 401 || code == 407) {
      d.authHandledCseqs.add(cseq);
      final challenge = DigestChallenge.pick(
          res.headerAll(code == 407 ? 'Proxy-Authenticate' : 'WWW-Authenticate'),
          isProxy: code == 407);
      if (isReinvite) {
        if (challenge == null || reinvite.authAttempted || d.terminating) {
          _onReinviteFailed(d, res, code);
          return;
        }
        reinvite.authAttempted = true;
        _sendReinvite(d, reinvite, challenge: challenge);
        return;
      }
      if (cseq != call.inviteCSeq || call.isConfirmed) return;
      if (d.terminating || d.cancelRequested) {
        _finishDialog(callId);
        return;
      }
      if (challenge == null || d.inviteAuthAttempted) {
        onError?.call('Call failed: authentication rejected');
        _endDialog(callId, SipCallEvent.failed);
        return;
      }
      d.inviteAuthAttempted = true;
      d.provisionalReceived = false;
      _sendInitialInvite(d, challenge: challenge);
      return;
    }

    if (isReinvite) {
      _onReinviteFailed(d, res, code);
      return;
    }
    if (cseq != call.inviteCSeq || call.isConfirmed) return;
    d.authHandledCseqs.add(cseq);
    if (d.terminating || d.cancelRequested) {
      // 487 after our CANCEL: the call was already reported as ended.
      _finishDialog(callId);
      return;
    }
    final declined = code == 486 || code == 600 || code == 603;
    if (!declined) {
      onError?.call('Call failed: $code ${res.reasonPhrase}');
    }
    _endDialog(
        callId, declined ? SipCallEvent.declined : SipCallEvent.failed);
  }

  void _onProvisional(_Dialog d, SipMessage res, int code) {
    final call = d.call;
    d.provisionalReceived = true;
    if (d.cancelRequested && !d.cancelSent) {
      _sendCancel(d);
      return;
    }
    if (d.terminating) return;
    if (code == 180 || code == 183) {
      final tag = extractTag(res.to ?? '');
      if (tag != null) call.remoteTag = tag;
      if (res.hasSdp) {
        // Early media (ringback or announcements from the far end).
        _applyRemoteSdp(d, res.body, isAnswer: true);
      }
      if (!d.ringingNotified) {
        d.ringingNotified = true;
        _emit(call.callId, SipCallEvent.ringing);
      }
    }
  }

  Future<void> _onInvite2xx(
      _Dialog d, SipMessage res, bool isReinvite) async {
    final call = d.call;
    final callId = call.callId;
    final cseq = res.cseqNumber ?? 0;

    final tag = extractTag(res.to ?? '');
    if (!call.isConfirmed) {
      if (tag != null) call.remoteTag = tag;
      final contact = res.header('Contact');
      if (contact != null) {
        call.contact = contact;
        call.remoteTarget = extractUri(contact) ?? call.remoteTarget;
      }
      call.routeSet = res.headerValues('Record-Route').reversed.toList();
    }

    if (d.terminating || d.cancelRequested) {
      // The answer crossed our CANCEL (or we already hung up): complete the
      // handshake and tear the call down so the callee is not left hanging.
      _sendAck(d, cseq);
      if (!call.isConfirmed) {
        call.isConfirmed = true;
        d.cancelTimer?.cancel();
        sipLog('[SIP] 200 OK crossed CANCEL for $callId, sending BYE');
        _sendInDialog(d, 'BYE');
      }
      return;
    }

    if (isReinvite) {
      final r = d.reinvite!;
      d.reinvite = null;
      _sendAck(d, cseq);
      if (r.kind == _ReinviteKind.hold) {
        call.isOnHold = true;
        if (res.hasSdp) _recordRemoteSdp(call, SdpInfo.parse(res.body), true);
        _refreshOtherLegs();
        sipLog('[SIP] Hold confirmed for $callId');
        _emit(callId, SipCallEvent.held);
        r.finish(true);
      } else {
        call.isOnHold = false;
        _audioOwnerCallId = callId;
        if (res.hasSdp) {
          _applyRemoteSdp(d, res.body, isAnswer: true);
        } else {
          _focusAudio(call);
        }
        _refreshOtherLegs();
        if (!call.isRemoteHold) await _startMicrophone();
        sipLog('[SIP] Resume confirmed for $callId');
        _emit(callId, SipCallEvent.resumed);
        r.finish(true);
      }
      return;
    }

    if (call.isConfirmed) {
      // Retransmitted 2xx (our ACK was lost): ACK again, nothing else.
      _sendAck(d, cseq);
      return;
    }
    if (cseq != call.inviteCSeq) return;

    call.isConfirmed = true;
    _sendAck(d, cseq);
    _audioOwnerCallId = callId;
    if (res.hasSdp) {
      _applyRemoteSdp(d, res.body, isAnswer: true);
    } else {
      _focusAudio(call);
    }
    _refreshOtherLegs();
    await _startMicrophone();
    sipLog('[SIP] Call confirmed: $callId');
    _emit(callId, SipCallEvent.confirmed);
  }

  // ── Hangup ─────────────────────────────────────────────────

  /// End a call: reject it while ringing (486), CANCEL it while ringing out,
  /// or send BYE when established. The `ended` event fires right away, the
  /// signalling finishes in the background.
  Future<void> hangupCall(String callId) async {
    final p = _pendingInvites[callId];
    if (p != null) {
      _rememberRejected(
          callId, _respond(p.request, 486, 'Busy Here', toTag: p.localTag));
      _removePending(callId);
      _emit(callId, SipCallEvent.ended);
      return;
    }
    final d = _dialogs[callId];
    if (d == null || d.terminating) return;
    final call = d.call;
    d.terminating = true;
    d.reinvite?.finish(false);
    d.reinvite = null;
    _releaseAudioFor(callId);

    if (!call.isIncoming && !call.isConfirmed) {
      // Not answered yet: there is no dialog to BYE, the INVITE has to be
      // CANCELed (RFC 3261 9.1). A CANCEL may only follow a provisional
      // response, so it waits for one if none came yet.
      d.cancelRequested = true;
      if (d.provisionalReceived) _sendCancel(d);
      d.cancelTimer = Timer(const Duration(seconds: 8), () {
        if (_dialogs[callId]?.call.isConfirmed != true) _finishDialog(callId);
      });
      _emit(callId, SipCallEvent.ended);
      return;
    }

    _emit(callId, SipCallEvent.ended);
    _sendInDialog(d, 'BYE');
  }

  void _sendCancel(_Dialog d) {
    final call = d.call;
    d.cancelSent = true;
    final branch = call.inviteBranch ?? _newBranch();
    final b = StringBuffer();
    _w(b, 'CANCEL ${d.inviteRequestUri ?? call.remoteTarget} SIP/2.0');
    _w(b, _via(branch));
    _w(b, 'Max-Forwards: 70');
    _w(b, 'From: ${call.fromHeader};tag=${call.localTag}');
    _w(b, 'To: ${call.toHeader}');
    _w(b, 'Call-ID: ${call.callId}');
    _w(b, 'CSeq: ${call.inviteCSeq} CANCEL');
    _w(b, 'User-Agent: $userAgent');
    _w(b, 'Content-Length: 0');
    _blank(b);
    _startTransaction(branch, 'CANCEL', b.toString());
  }

  // ── Hold / resume ──────────────────────────────────────────

  /// Put a call on hold (re-INVITE with a=sendonly). Completes with true
  /// once the far end accepted it.
  Future<bool> holdCall(String callId) async {
    final d = _dialogs[callId];
    if (d == null || d.terminating) {
      onError?.call('No active call to hold: $callId');
      return false;
    }
    if (!d.call.isConfirmed) {
      onError?.call('Cannot hold a call that is not established yet');
      return false;
    }
    final pending = d.reinvite;
    if (pending != null) {
      if (pending.kind == _ReinviteKind.hold) return pending.completer.future;
      onError?.call('Resume still in progress for $callId');
      return false;
    }
    if (d.call.isOnHold) return true;

    // Stop the microphone only when holding the call that owns it.
    if (_audioOwnerCallId == null || _audioOwnerCallId == callId) {
      media?.stopMicrophone();
      _audioOwnerCallId = null;
    }
    final r = _PendingReinvite(_ReinviteKind.hold);
    d.reinvite = r;
    _sendReinvite(d, r);
    return r.completer.future;
  }

  /// Resume a held call (re-INVITE with a=sendrecv). Completes with true
  /// once the far end accepted it.
  Future<bool> unholdCall(String callId) async {
    final d = _dialogs[callId];
    if (d == null || d.terminating) {
      onError?.call('No active call to unhold: $callId');
      return false;
    }
    final pending = d.reinvite;
    if (pending != null) {
      if (pending.kind == _ReinviteKind.unhold) {
        return pending.completer.future;
      }
      onError?.call('Hold still in progress for $callId');
      return false;
    }
    if (!d.call.isOnHold) return true;

    // Reuse the shared RTP socket, only reopen it when it is gone.
    final rtpPort = await media?.prepare();
    if (media != null && rtpPort == null) {
      onError?.call('Failed to initialize RTP for unhold');
      return false;
    }
    if (d.terminating || d.reinvite != null) return false;
    final r = _PendingReinvite(_ReinviteKind.unhold);
    d.reinvite = r;
    _sendReinvite(d, r);
    return r.completer.future;
  }

  void _sendReinvite(_Dialog d, _PendingReinvite r,
      {DigestChallenge? challenge}) {
    final call = d.call;
    call.dialogCseq++;
    r.cseq = call.dialogCseq;
    r.sdp ??= _sdpFor(call,
        direction: r.kind == _ReinviteKind.hold
            ? MediaDirection.sendonly
            : MediaDirection.sendrecv);
    final sdp = r.sdp!;
    final body = utf8.encode(sdp);
    final uri = call.remoteTarget ?? _registrar;
    final branch = _newBranch();

    final b = StringBuffer();
    _w(b, 'INVITE $uri SIP/2.0');
    _w(b, _via(branch));
    for (final route in call.routeSet) {
      _w(b, 'Route: $route');
    }
    _w(b, 'Max-Forwards: 70');
    _w(b, 'From: ${_localDialogHeader(call)}');
    _w(b, 'To: ${_remoteDialogHeader(call)}');
    _w(b, 'Call-ID: ${call.callId}');
    _w(b, 'CSeq: ${r.cseq} INVITE');
    _w(b, 'Contact: $_contact');
    _w(b, 'Allow: $_allow');
    _w(b, 'User-Agent: $userAgent');
    if (challenge != null) {
      _w(b,
          '${challenge.responseHeaderName}: ${challenge.authorize(method: 'INVITE', uri: uri, username: _authUsername, password: _password)}');
    }
    _w(b, 'Content-Type: application/sdp');
    _w(b, 'Content-Length: ${body.length}');
    _blank(b);
    b.write(sdp);

    final callId = call.callId;
    _startTransaction(branch, 'INVITE', b.toString(), onTimeout: () {
      final dd = _dialogs[callId];
      if (dd == null || dd.reinvite != r) return;
      _reinviteFailed(dd, r, 'no answer from the server');
    });
  }

  void _onReinviteFailed(_Dialog d, SipMessage res, int code) {
    final r = d.reinvite;
    if (r == null) return;
    final callId = d.call.callId;
    if (code == 491 && !r.glareRetried) {
      // Glare: retry after 2.1 to 4 s (RFC 3261 14.1).
      d.reinvite = null;
      final retry = _PendingReinvite(r.kind, r.completer)..glareRetried = true;
      _later(Duration(milliseconds: 2100 + _rng.nextInt(1900)), () {
        final dd = _dialogs[callId];
        if (dd == null || dd.terminating || dd.reinvite != null) {
          retry.finish(false);
          return;
        }
        dd.reinvite = retry;
        _sendReinvite(dd, retry);
      });
      return;
    }
    if (code == 481) {
      // The far end no longer knows this dialog.
      d.reinvite = null;
      r.finish(false);
      _endDialog(callId, SipCallEvent.ended);
      return;
    }
    _reinviteFailed(d, r, '$code ${res.reasonPhrase}');
  }

  void _reinviteFailed(_Dialog d, _PendingReinvite r, String reason) {
    d.reinvite = null;
    final call = d.call;
    if (r.kind == _ReinviteKind.hold) {
      // The call is still live: give it its microphone back.
      if (_audioOwnerCallId == null || _audioOwnerCallId == call.callId) {
        _audioOwnerCallId = call.callId;
        if (!call.isRemoteHold) _startMicrophone();
      }
      onError?.call('Hold failed: $reason');
    } else {
      onError?.call('Resume failed: $reason');
    }
    r.finish(false);
  }

  // ── Transfer ───────────────────────────────────────────────

  /// Blind-transfer an established call to [target] (extension, number or
  /// `sip:` URI) with REFER (RFC 3515). Completes with true when the server
  /// accepted the REFER. On success the server takes the call over and the
  /// events `transferred` and `ended` follow.
  Future<bool> transferCall(String callId, String target) async {
    final d = _dialogs[callId];
    if (d == null || d.terminating || !d.call.isConfirmed) {
      onError?.call('No established call to transfer');
      return false;
    }
    final t = target.trim();
    if (t.isEmpty) {
      onError?.call('Transfer target is required');
      return false;
    }
    d.transferring = true;
    final accepted = Completer<bool>();
    d.transferAccepted = accepted;
    _sendInDialog(d, 'REFER', extraHeaders: [
      'Refer-To: <${_targetUri(t)}>',
      'Referred-By: <$_aor>',
    ]);
    d.transferTimer?.cancel();
    d.transferTimer = Timer(const Duration(seconds: 30), () {
      // Accepted but the server never reported back or hung up our leg:
      // drop it locally so the user is not stuck with it.
      if (d.transferring && _dialogs.containsKey(callId)) {
        d.transferring = false;
        sipLog('[SIP] No result for transfer of $callId, ending our leg');
        hangupCall(callId);
      }
    });
    return accepted.future;
  }

  // ── DTMF ───────────────────────────────────────────────────

  /// Send DTMF [digits] (0-9, *, #, A-D) on an established call. Uses RFC
  /// 4733 telephone-event packets when the far end supports them, SIP INFO
  /// otherwise.
  Future<void> sendDtmf(String callId, String digits,
      {int durationMs = 160}) async {
    for (final digit in digits.toUpperCase().split('')) {
      if (!RegExp(r'^[0-9*#A-D]$').hasMatch(digit)) continue;
      final d = _dialogs[callId];
      if (d == null || d.terminating || !d.call.isConfirmed) {
        onError?.call('No established call to send DTMF on');
        return;
      }
      final rtp = d.call.dtmfPayloadType != null &&
          media != null &&
          _audioOwnerCallId == callId;
      if (rtp) {
        await media!.sendDtmf(digit, durationMs: durationMs);
      } else {
        _sendInDialog(d, 'INFO',
            body: 'Signal=$digit\r\nDuration=$durationMs\r\n',
            contentType: 'application/dtmf-relay');
        await Future<void>.delayed(Duration(milliseconds: durationMs));
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  // ── In-dialog requests (BYE, REFER, INFO) ──────────────────

  void _sendInDialog(_Dialog d, String method,
      {List<String> extraHeaders = const [],
      String? body,
      String? contentType,
      DigestChallenge? challenge}) {
    final request =
        challenge == null ? _InDialogRequest(extraHeaders, body, contentType) : d.requests[method]!;
    d.requests[method] = request;
    final call = d.call;
    call.dialogCseq++;
    request.cseq = call.dialogCseq;
    final uri = call.remoteTarget ?? _registrar;
    final branch = _newBranch();
    final bytes = request.body == null ? null : utf8.encode(request.body!);

    final b = StringBuffer();
    _w(b, '$method $uri SIP/2.0');
    _w(b, _via(branch));
    for (final route in call.routeSet) {
      _w(b, 'Route: $route');
    }
    _w(b, 'Max-Forwards: 70');
    _w(b, 'From: ${_localDialogHeader(call)}');
    _w(b, 'To: ${_remoteDialogHeader(call)}');
    _w(b, 'Call-ID: ${call.callId}');
    _w(b, 'CSeq: ${request.cseq} $method');
    _w(b, 'Contact: $_contact');
    for (final h in request.extraHeaders) {
      _w(b, h);
    }
    _w(b, 'User-Agent: $userAgent');
    if (challenge != null) {
      _w(b,
          '${challenge.responseHeaderName}: ${challenge.authorize(method: method, uri: uri, username: _authUsername, password: _password, body: request.body ?? '')}');
    }
    if (bytes != null) {
      _w(b, 'Content-Type: ${request.contentType}');
      _w(b, 'Content-Length: ${bytes.length}');
      _blank(b);
      b.write(request.body);
    } else {
      _w(b, 'Content-Length: 0');
      _blank(b);
    }

    final callId = call.callId;
    _startTransaction(branch, method, b.toString(), onTimeout: () {
      if (method == 'BYE') {
        _finishDialog(callId);
      } else if (method == 'REFER') {
        final dd = _dialogs[callId];
        if (dd != null && dd.transferring) {
          dd.transferring = false;
          dd.transferTimer?.cancel();
          if (!(dd.transferAccepted?.isCompleted ?? true)) {
            dd.transferAccepted!.complete(false);
          }
          onError?.call('Transfer failed: no answer from the server');
        }
      }
    });
  }

  void _onInDialogResponse(SipMessage res, int code, String method) {
    if (code < 200) return;
    final callId = res.callId;
    if (callId == null) return;
    final d = _dialogs[callId];
    if (d == null) return;
    final request = d.requests[method];
    if (request == null || res.cseqNumber != request.cseq) return;

    if ((code == 401 || code == 407) && !request.authAttempted) {
      final challenge = DigestChallenge.pick(
          res.headerAll(code == 407 ? 'Proxy-Authenticate' : 'WWW-Authenticate'),
          isProxy: code == 407);
      if (challenge != null) {
        request.authAttempted = true;
        _sendInDialog(d, method, challenge: challenge);
        return;
      }
    }

    switch (method) {
      case 'BYE':
        _finishDialog(callId);
      case 'REFER':
        final accepted = d.transferAccepted;
        if (code < 300) {
          if (accepted != null && !accepted.isCompleted) accepted.complete(true);
        } else {
          d.transferring = false;
          d.transferTimer?.cancel();
          if (accepted != null && !accepted.isCompleted) {
            accepted.complete(false);
          }
          onError?.call(
              'Transfer refused by the server: $code ${res.reasonPhrase}');
        }
      case 'INFO':
        if (code >= 300) {
          sipLog('[SIP] INFO refused: $code ${res.reasonPhrase}');
        }
    }
  }

  // ── ACK ────────────────────────────────────────────────────

  /// ACK for a 2xx: a new transaction with its own branch, sent to the
  /// remote target with the route set, carrying the INVITE's CSeq number.
  void _sendAck(_Dialog d, int cseq) {
    final call = d.call;
    final b = StringBuffer();
    _w(b, 'ACK ${call.remoteTarget ?? _registrar} SIP/2.0');
    _w(b, _via(_newBranch()));
    for (final route in call.routeSet) {
      _w(b, 'Route: $route');
    }
    _w(b, 'Max-Forwards: 70');
    _w(b, 'From: ${_localDialogHeader(call)}');
    _w(b, 'To: ${_remoteDialogHeader(call)}');
    _w(b, 'Call-ID: ${call.callId}');
    _w(b, 'CSeq: $cseq ACK');
    _w(b, 'User-Agent: $userAgent');
    _w(b, 'Content-Length: 0');
    _blank(b);
    _send(b.toString());
  }

  /// ACK for a non-2xx final response: part of the INVITE transaction, so
  /// it reuses the INVITE's branch and CSeq number (17.1.1.3).
  void _sendNon2xxAck(SipMessage res, String requestUri, List<String> routes) {
    final via = res.topVia ?? '';
    final branch = headerParam(via, 'branch') ?? _newBranch();
    final b = StringBuffer();
    _w(b, 'ACK $requestUri SIP/2.0');
    _w(b, _via(branch));
    for (final route in routes) {
      _w(b, 'Route: $route');
    }
    _w(b, 'Max-Forwards: 70');
    _w(b, 'From: ${res.from ?? ''}');
    _w(b, 'To: ${res.to ?? ''}');
    _w(b, 'Call-ID: ${res.callId ?? ''}');
    _w(b, 'CSeq: ${res.cseqNumber ?? 0} ACK');
    _w(b, 'User-Agent: $userAgent');
    _w(b, 'Content-Length: 0');
    _blank(b);
    _send(b.toString());
  }

  /// A 2xx for a call we already forgot: ACK it and hang up.
  void _orphanAckAndBye(SipMessage res) {
    final contact = res.header('Contact');
    final target = (contact != null ? extractUri(contact) : null) ??
        extractUri(res.to ?? '') ??
        _registrar;
    final routes = res.headerValues('Record-Route').reversed.toList();
    final cseq = res.cseqNumber ?? 0;
    for (final method in ['ACK', 'BYE']) {
      final b = StringBuffer();
      _w(b, '$method $target SIP/2.0');
      _w(b, _via(_newBranch()));
      for (final route in routes) {
        _w(b, 'Route: $route');
      }
      _w(b, 'Max-Forwards: 70');
      _w(b, 'From: ${res.from ?? ''}');
      _w(b, 'To: ${res.to ?? ''}');
      _w(b, 'Call-ID: ${res.callId ?? ''}');
      _w(b, 'CSeq: ${method == 'ACK' ? cseq : cseq + 1} $method');
      _w(b, 'User-Agent: $userAgent');
      _w(b, 'Content-Length: 0');
      _blank(b);
      _send(b.toString());
    }
  }

  // ── Media ──────────────────────────────────────────────────

  String _sdpFor(SipCall call,
      {MediaDirection direction = MediaDirection.sendrecv,
      int? codec,
      int? dtmf,
      bool bumpVersion = true}) {
    if (bumpVersion) call.sdpVersion++;
    return buildSdp(
      localIp: _sentByHost,
      rtpPort: media?.localPort ?? 0,
      sessionId: call.sdpSessionId,
      sessionVersion: call.sdpVersion,
      direction: direction,
      codec: codec,
      dtmf: dtmf,
      sessionName: userAgent,
    );
  }

  void _recordRemoteSdp(SipCall call, SdpInfo info, bool isAnswer) {
    final codec = info.chooseCodec(isAnswer: isAnswer);
    if (codec != null) call.payloadType = codec;
    if (info.telephoneEvent != null) call.dtmfPayloadType = info.telephoneEvent;
    if (info.endpoint != null && info.host != '0.0.0.0') {
      call.remoteRtpHost = info.host;
      call.remoteRtpPort = info.port;
    }
  }

  /// [sdp] arrived for the call of [d]: record its endpoint and codec and
  /// focus the audio on it when this call owns the audio.
  void _applyRemoteSdp(_Dialog d, String sdp, {bool isAnswer = false}) {
    final call = d.call;
    _recordRemoteSdp(call, SdpInfo.parse(sdp), isAnswer);
    if (_audioOwnerCallId == null || _audioOwnerCallId == call.callId) {
      _focusAudio(call);
    }
    _refreshOtherLegs();
  }

  void _focusAudio(SipCall call) {
    final host = call.remoteRtpHost;
    final port = call.remoteRtpPort;
    if (host == null || port == null || port == 0) return;
    media?.setRemote(host, port,
        payloadType: call.payloadType, dtmfPayloadType: call.dtmfPayloadType);
  }

  /// Tell the RTP receiver which endpoints belong to the other calls, so a
  /// held call's music is never played.
  void _refreshOtherLegs() {
    media?.setIgnoredEndpoints({
      for (final d in _dialogs.values)
        if (d.call.callId != _audioOwnerCallId &&
            !d.terminating &&
            d.call.remoteRtp != null)
          d.call.remoteRtp!,
    });
  }

  Future<void> _startMicrophone() async {
    final m = media;
    if (m == null) return;
    try {
      final ok = await m.startMicrophone();
      if (!ok) {
        onError?.call(
            'Microphone failed to start, the other side cannot hear you');
      }
    } catch (e) {
      onError?.call('Microphone failed to start: $e');
    }
  }

  /// Release audio only as far as [callId] owns it. The RTP socket and
  /// microphone are shared, ending one call must not silence the others.
  void _releaseAudioFor(String callId) {
    final othersRemain = _dialogs.values
        .any((d) => d.call.callId != callId && !d.terminating);
    if (!othersRemain) {
      try {
        media?.release();
      } catch (_) {}
      _audioOwnerCallId = null;
    } else if (_audioOwnerCallId == callId) {
      media?.stopMicrophone();
      _audioOwnerCallId = null;
    }
    _refreshOtherLegs();
  }

  // ── Dialog bookkeeping ─────────────────────────────────────

  /// The far end ended (or never set up) the call.
  void _endDialog(String callId, SipCallEvent event) {
    final d = _dialogs[callId];
    if (d == null) return;
    d.terminating = true;
    d.reinvite?.finish(false);
    d.reinvite = null;
    _releaseAudioFor(callId);
    _finishDialog(callId);
    _emit(callId, event);
  }

  /// Forget a dialog whose signalling is complete.
  void _finishDialog(String callId) {
    final d = _dialogs.remove(callId);
    if (d == null) return;
    d.cancelTimers();
    d.reinvite?.finish(false);
    if (!(d.transferAccepted?.isCompleted ?? true)) {
      d.transferAccepted!.complete(false);
    }
    _okRetransmits.removeWhere((key, ok) {
      if (!key.startsWith('$callId:')) return false;
      ok.timer?.cancel();
      return true;
    });
    if (_audioOwnerCallId == callId) _audioOwnerCallId = null;
  }

  void _removePending(String callId) {
    _pendingInvites.remove(callId)?.ttl?.cancel();
  }

  /// Keep our final response to a rejected INVITE for a while, so a
  /// retransmitted INVITE gets it again instead of ringing as a new call.
  void _rememberRejected(String callId, String response) {
    _rejected[callId] = response;
    _later(_txTimeout, () => _rejected.remove(callId));
  }

  void _emit(String callId, SipCallEvent event) {
    if (event.isTerminal) {
      if (!_terminalNotified.add(callId)) return;
      _later(const Duration(minutes: 2), () => _terminalNotified.remove(callId));
    }
    onCallStateChanged?.call(callId, event);
  }

  // ── Transactions and retransmissions ───────────────────────

  void _startTransaction(String branch, String method, String message,
      {void Function()? onTimeout}) {
    final key = '$branch:$method';
    _transactions.remove(key)?.timer?.cancel();
    final tx = _ClientTransaction(key, message, method == 'INVITE', onTimeout, _t1);
    _transactions[key] = tx;
    _send(message);
    _armTransaction(tx);
  }

  void _armTransaction(_ClientTransaction tx) {
    tx.timer = Timer(tx.interval, () {
      if (_transactions[tx.key] != tx) return;
      tx.elapsed += tx.interval;
      if (tx.elapsed >= _txTimeout) {
        _transactions.remove(tx.key);
        tx.onTimeout?.call();
        return;
      }
      _send(tx.message, retransmit: true);
      final next = tx.interval * 2;
      tx.interval = tx.isInvite ? next : (next > _t2 ? _t2 : next);
      _armTransaction(tx);
    });
  }

  void _transactionResponse(String key, int code) {
    final tx = _transactions[key];
    if (tx == null) return;
    if (code < 200) {
      if (tx.isInvite) {
        // A provisional stops INVITE retransmissions, the final answer can
        // take as long as the callee needs to pick up.
        tx.timer?.cancel();
        _transactions.remove(key);
      }
      return;
    }
    tx.timer?.cancel();
    _transactions.remove(key);
  }

  void _startOkRetransmit(String callId, int cseq, String message,
      {bool initial = false}) {
    final key = '$callId:$cseq';
    _okRetransmits.remove(key)?.timer?.cancel();
    final ok = _OkRetransmit(message, initial, _t1);
    _okRetransmits[key] = ok;
    _armOk(key, ok, callId);
  }

  void _armOk(String key, _OkRetransmit ok, String callId) {
    ok.timer = Timer(ok.interval, () {
      if (_okRetransmits[key] != ok) return;
      ok.elapsed += ok.interval;
      if (ok.elapsed >= _txTimeout) {
        _okRetransmits.remove(key);
        if (ok.initial && _dialogs.containsKey(callId)) {
          // No ACK for our answer: the call never got established on the
          // far side, end it (RFC 3261 13.3.1.4).
          sipLog('[SIP] No ACK for answered call $callId, hanging up');
          hangupCall(callId);
        }
        return;
      }
      _send(ok.message, retransmit: true);
      final next = ok.interval * 2;
      ok.interval = next > _t2 ? _t2 : next;
      _armOk(key, ok, callId);
    });
  }

  void _stopOkRetransmit(String callId, int cseq) {
    _okRetransmits.remove('$callId:$cseq')?.timer?.cancel();
  }

  void _later(Duration delay, void Function() action) {
    late final Timer t;
    t = Timer(delay, () {
      _miscTimers.remove(t);
      action();
    });
    _miscTimers.add(t);
  }

  // ── Unregister / disconnect ────────────────────────────────

  /// End the registration cleanly: hang up live calls, send
  /// `REGISTER Expires: 0` and wait (up to 3 s) for the server to confirm,
  /// then release the socket. Without this the server keeps a binding to a
  /// dead port for up to [SipConfiguration.registerInterval] seconds.
  Future<void> unregister() async {
    if (_closing || _closed) return;
    if (_socket == null) {
      await disconnect();
      return;
    }
    _closing = true;
    try {
      for (final callId in [..._pendingInvites.keys, ..._dialogs.keys]) {
        try {
          await hangupCall(callId);
        } catch (_) {}
      }
      if (_isRegistered) await _sendUnregister();
    } catch (e) {
      sipLog('[SIP] Un-REGISTER failed (the binding will expire): $e');
    } finally {
      _closing = false;
    }
    await disconnect();
  }

  Future<void> _sendUnregister() async {
    _refreshTimer?.cancel();
    _retryTimer?.cancel();
    _unregistering = true;
    final completer = Completer<void>();
    _unregisterCompleter = completer;
    _regUsedCachedNonce = _regChallenge != null;
    _register(withAuth: _regChallenge != null);
    await completer.future
        .timeout(const Duration(seconds: 3), onTimeout: () {})
        .catchError((Object _) {});
    _unregistering = false;
    _unregisterCompleter = null;
  }

  void _completeUnregister() {
    final c = _unregisterCompleter;
    _unregisterCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Release the socket and all state without telling the server. Use
  /// [unregister] for a clean shutdown. Safe to call more than once.
  Future<void> disconnect() async {
    if (_closed) return;
    _closed = true;
    _refreshTimer?.cancel();
    _keepAliveTimer?.cancel();
    _retryTimer?.cancel();
    for (final t in _miscTimers) {
      t.cancel();
    }
    _miscTimers.clear();
    for (final tx in _transactions.values) {
      tx.timer?.cancel();
    }
    _transactions.clear();
    for (final ok in _okRetransmits.values) {
      ok.timer?.cancel();
    }
    _okRetransmits.clear();

    final leftover = [..._pendingInvites.keys, ..._dialogs.keys];
    for (final p in _pendingInvites.values) {
      p.ttl?.cancel();
    }
    _pendingInvites.clear();
    for (final d in _dialogs.values) {
      d.cancelTimers();
      d.reinvite?.finish(false);
    }
    _dialogs.clear();
    _rejected.clear();
    _audioOwnerCallId = null;
    try {
      media?.release();
    } catch (_) {}

    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    _sender = null;
    _localPort = null;
    _unregistering = false;
    _completeUnregister();

    for (final callId in leftover) {
      _emit(callId, SipCallEvent.ended);
    }
    _setRegistered(false);
  }

  // ── Responses ──────────────────────────────────────────────

  /// Build and send a response to [req]. Returns the raw message.
  String _respond(SipMessage req, int code, String reason,
      {String? toTag, List<String> extraHeaders = const []}) {
    final msg =
        _buildResponse(req, code, reason, toTag: toTag, extraHeaders: extraHeaders);
    _send(msg);
    return msg;
  }

  String _buildResponse(SipMessage req, int code, String reason,
      {String? toTag,
      bool withContact = false,
      List<String> extraHeaders = const [],
      String? body}) {
    final b = StringBuffer();
    _w(b, 'SIP/2.0 $code $reason');
    for (final via in req.headerAll('Via')) {
      _w(b, 'Via: $via');
    }
    if (req.method == 'INVITE' && code > 100 && code < 300) {
      for (final rr in req.headerAll('Record-Route')) {
        _w(b, 'Record-Route: $rr');
      }
    }
    _w(b, 'From: ${req.from ?? ''}');
    final to = req.to ?? '';
    if (code == 100 || extractTag(to) != null) {
      _w(b, 'To: $to');
    } else {
      _w(b, 'To: $to;tag=${toTag ?? _newTag()}');
    }
    _w(b, 'Call-ID: ${req.callId ?? ''}');
    _w(b, 'CSeq: ${req.header('CSeq') ?? ''}');
    if (withContact) _w(b, 'Contact: $_contact');
    for (final h in extraHeaders) {
      _w(b, h);
    }
    _w(b, 'User-Agent: $userAgent');
    if (body != null) {
      _w(b, 'Content-Type: application/sdp');
      _w(b, 'Content-Length: ${utf8.encode(body).length}');
      _blank(b);
      b.write(body);
    } else {
      _w(b, 'Content-Length: 0');
      _blank(b);
    }
    return b.toString();
  }

  // ── Helpers ────────────────────────────────────────────────

  static void _w(StringBuffer b, String line) => b.write('$line\r\n');
  static void _blank(StringBuffer b) => b.write('\r\n');

  String _via(String branch) =>
      'Via: SIP/2.0/UDP $_sentByHost:$_sentByPort;rport;branch=$branch';

  String _localDialogHeader(SipCall call) =>
      '${call.localHeader};tag=${call.localTag}';

  String _remoteDialogHeader(SipCall call) =>
      '${call.remoteHeader}${call.remoteTag != null ? ';tag=${call.remoteTag}' : ''}';

  String _targetUri(String destination) {
    final d = destination.trim();
    if (d.toLowerCase().startsWith('sip:') ||
        d.toLowerCase().startsWith('sips:')) {
      return d;
    }
    if (d.contains('@')) return 'sip:$d';
    return 'sip:$d@$_server';
  }

  void _send(String message, {bool retransmit = false}) {
    final sender = _sender;
    final a = _serverAddress;
    if (sender == null || a == null) {
      sipLog('[SIP] Not sent, socket closed: ${message.split('\r\n').first}');
      return;
    }
    _trace(retransmit ? '>>> (again)' : '>>>', message,
        message.split('\r\n').first);
    sender.send(utf8.encode(message), a, _port);
  }

  void _trace(String direction, String message, String firstLine) {
    if (sipLogger == null) return;
    if (!sipLogFullMessages) {
      sipLog('[SIP] $direction $firstLine');
      return;
    }
    final masked = message.replaceAll(
        RegExp(r'^((?:Proxy-)?Authorization:).*$',
            multiLine: true, caseSensitive: false),
        r'$1 <hidden>');
    sipLog('[SIP] $direction\n$masked');
  }

  static String _hex(int length) {
    const chars = '0123456789abcdef';
    final b = StringBuffer();
    for (var i = 0; i < length; i++) {
      b.write(chars[_rng.nextInt(16)]);
    }
    return b.toString();
  }

  String _newCallId() => '${_hex(24)}@${_localIp ?? 'sip_helper'}';
  String _newTag() => _hex(10);
  String _newBranch() => 'z9hG4bK${_hex(16)}';

  // ── Local IP detection ─────────────────────────────────────

  /// Find the local address that routes to the SIP server.
  Future<String> _detectLocalIp() async {
    // 1. TCP connect: the OS picks the route and reports the local address.
    try {
      final tcp = await Socket.connect(_serverAddress, _port,
          timeout: const Duration(milliseconds: 1500));
      final ip = tcp.address.address;
      tcp.destroy();
      if (ip != '0.0.0.0') {
        sipLog('[SIP] Local IP from TCP connect: $ip');
        return ip;
      }
    } catch (_) {}

    List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    } catch (_) {
      return '0.0.0.0';
    }

    bool usable(InternetAddress a) =>
        !a.isLoopback && !a.isLinkLocal && !a.address.startsWith('169.254.');

    // 2. Same /24 as the server.
    final server = _serverAddress?.address.split('.');
    if (server != null && server.length == 4) {
      final prefix = '${server[0]}.${server[1]}.${server[2]}.';
      for (final iface in interfaces) {
        for (final a in iface.addresses) {
          if (usable(a) && a.address.startsWith(prefix)) {
            sipLog('[SIP] Local IP from subnet match: ${a.address}');
            return a.address;
          }
        }
      }
    }

    // 3. Physical interfaces first (Wi-Fi / Ethernet, then cellular),
    //    virtual adapters last.
    int rank(String name) {
      final n = name.toLowerCase();
      const virtual = ['vethernet', 'virtual', 'vmware', 'vbox', 'docker',
          'hyper-v', 'wsl', 'loopback', 'tailscale', 'zerotier'];
      if (virtual.any(n.contains)) return 5;
      if (n.startsWith('wlan') || n.startsWith('en0') || n.contains('wi-fi') ||
          n.contains('wifi') || n.startsWith('eth') || n.contains('ethernet') ||
          n.startsWith('en')) {
        return 0;
      }
      if (n.startsWith('rmnet') || n.startsWith('pdp_ip') ||
          n.startsWith('ccmni') || n.startsWith('v4-')) {
        return 1;
      }
      return 2;
    }

    final candidates = <(int, String)>[];
    for (final iface in interfaces) {
      for (final a in iface.addresses) {
        if (usable(a)) candidates.add((rank(iface.name), a.address));
      }
    }
    if (candidates.isEmpty) return '0.0.0.0';
    candidates.sort((x, y) => x.$1.compareTo(y.$1));
    sipLog('[SIP] Local IP from interface list: ${candidates.first.$2}');
    return candidates.first.$2;
  }
}
