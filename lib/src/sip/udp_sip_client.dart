import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../logging.dart';
import 'sip_call.dart';

/// Pending INVITE: stores raw message + dialog tag we assigned
class _PendingInvite {
  final String rawMessage;
  final String localTag;

  _PendingInvite({required this.rawMessage, required this.localTag});
}

/// Custom UDP SIP client for native UDP communication with Asterisk chan_sip
class UdpSipClient {
  RawDatagramSocket? _socket;
  final String _server;
  final int _port;
  final String _username;
  final String _password;
  final String _displayName;

  InternetAddress? _serverAddress;
  int? _localPort;
  String? _localIP;
  String? _registrationCallId;
  int _cseq = 1;
  String? _branch;
  String? _tag;
  Timer? _keepAliveTimer;

  // Store active calls, pending invites, and ended call IDs
  final Map<String, SipCall> _activeCalls = {};
  final Map<String, _PendingInvite> _pendingInvites = {};
  final Set<String> _endedCallIds = {};
  final Set<String> _holdPendingCallIds = {};

  bool _isRegistered = false;
  bool get isRegistered => _isRegistered;

  // Callbacks
  Function(bool)? onRegistrationStateChanged;
  Function(String callerNumber, String callId)? onIncomingCall;
  Function(String callId, String state)? onCallStateChanged;
  Function(String)? onError;

  // Audio callbacks (decoupled from concrete implementations)
  Future<int?> Function()? onRtpInitialize;
  void Function(String host, int port)? onRtpSetRemoteEndpoint;
  void Function(Uint8List data, int payloadType)? onRtpSendAudio;
  bool Function()? onRtpIsActive;
  int? Function()? onRtpGetLocalPort;
  Future<void> Function()? onMicrophoneStart;
  void Function()? onMicrophoneStop;
  void Function()? onAudioCleanup;

  UdpSipClient({
    required String server,
    required int port,
    required String username,
    required String password,
    String? displayName,
  })  : _server = server,
        _port = port,
        _username = username,
        _password = password,
        _displayName = (displayName != null && displayName.isNotEmpty)
            ? displayName
            : username;

  // ── SIP message helpers ───────────────────────────────────

  /// Write a SIP header line with proper \r\n termination
  static void _w(StringBuffer buf, String line) => buf.write('$line\r\n');

  /// Write blank line (header/body separator)
  static void _blank(StringBuffer buf) => buf.write('\r\n');

  // ── Connect ───────────────────────────────────────────────

  /// Initialize and connect
  Future<void> connect() async {
    try {
      _serverAddress = (await InternetAddress.lookup(_server)).first;

      // Get local IP by creating a temporary connection
      try {
        final tempSocket = await Socket.connect(
          _serverAddress!, _port,
          timeout: const Duration(seconds: 2),
        );
        _localIP = tempSocket.address.address;
        tempSocket.destroy();
      } catch (_) {
        // Fallback: get local interfaces
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        );
        for (var iface in interfaces) {
          for (var addr in iface.addresses) {
            if (!addr.isLoopback && addr.address.startsWith('192.168')) {
              _localIP = addr.address;
              break;
            }
          }
          if (_localIP != null) break;
        }
        _localIP ??= '0.0.0.0';
      }

      // Bind to any available port
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _localPort = _socket!.port;

      sipLog('[SIP] Local IP: $_localIP, SIP port: $_localPort');
      sipLog('[SIP] Server: $_server:$_port');

      // Generate unique identifiers for registration
      _registrationCallId = _generateCallId();
      _tag = _generateTag();

      // Listen for incoming messages
      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _socket!.receive();
          if (datagram != null) {
            final message = utf8.decode(datagram.data);
            _handleIncomingMessage(message);
          }
        }
      });

      await _register();
    } catch (e) {
      onError?.call('Connection failed: $e');
      rethrow;
    }
  }

  // ── Registration ──────────────────────────────────────────

  Future<void> _register() async {
    _branch = _generateBranch();
    final message = _buildRegisterMessage();
    await _sendMessage(message);
  }

  String _buildRegisterMessage({String? nonce, String? realm, String? qop}) {
    final uri = 'sip:$_server';
    final from = '<sip:$_username@$_server>';
    final to = '<sip:$_username@$_server>';
    final via = 'SIP/2.0/UDP $_localIP:$_localPort;branch=$_branch';
    final contact = '<sip:$_username@$_localIP:$_localPort>';

    final buf = StringBuffer();
    _w(buf, 'REGISTER $uri SIP/2.0');
    _w(buf, 'Via: $via');
    _w(buf, 'From: "$_displayName" $from;tag=$_tag');
    _w(buf, 'To: $to');
    _w(buf, 'Call-ID: $_registrationCallId');
    _w(buf, 'CSeq: $_cseq REGISTER');
    _w(buf, 'Contact: $contact');
    _w(buf, 'Max-Forwards: 70');
    _w(buf, 'Expires: 3600');
    _w(buf, 'User-Agent: IQ-SIP');

    if (nonce != null && realm != null) {
      _w(buf, 'Authorization: ${_buildAuthHeader('REGISTER', uri, nonce, realm, qop: qop)}');
    }

    _w(buf, 'Content-Length: 0');
    _blank(buf);

    return buf.toString();
  }

  String _buildAuthHeader(
      String method, String uri, String nonce, String realm,
      {String? qop}) {
    final ha1 =
        md5.convert(utf8.encode('$_username:$realm:$_password')).toString();
    final ha2 = md5.convert(utf8.encode('$method:$uri')).toString();

    sipLog('[SIP] Auth: user=$_username, realm=$realm, uri=$uri');

    if (qop != null && qop.contains('auth')) {
      // RFC 2617 qop=auth variant
      final nc = '00000001';
      final cnonce = Random().nextInt(1000000000).toRadixString(16);
      final response = md5
          .convert(utf8.encode('$ha1:$nonce:$nc:$cnonce:auth:$ha2'))
          .toString();

      return 'Digest username="$_username", realm="$realm", '
          'nonce="$nonce", uri="$uri", response="$response", '
          'algorithm=MD5, qop=auth, nc=$nc, cnonce="$cnonce"';
    } else {
      final response =
          md5.convert(utf8.encode('$ha1:$nonce:$ha2')).toString();

      return 'Digest username="$_username", realm="$realm", '
          'nonce="$nonce", uri="$uri", response="$response", algorithm=MD5';
    }
  }

  // ── Incoming message dispatch ─────────────────────────────

  void _handleIncomingMessage(String rawMessage) {
    try {
      // Normalize: strip \r so we parse with \n only internally
      final message = rawMessage.replaceAll('\r', '');
      final lines = message.split('\n');
      if (lines.isEmpty) return;

      final statusLine = lines[0].trim();
      sipLog('[SIP] <<< $statusLine');

      if (statusLine.startsWith('SIP/2.0')) {
        _handleResponse(statusLine, message);
      } else {
        _handleRequest(statusLine, message);
      }
    } catch (e) {
      onError?.call('Error handling SIP message: $e');
      sipLog('[SIP] Error: $e');
    }
  }

  // ── SIP Responses ─────────────────────────────────────────

  Future<void> _handleResponse(String statusLine, String message) async {
    final cseqMethod = _getCSeqMethod(message);

    if (statusLine.contains(' 401 ')) {
      // Unauthorized — need to authenticate
      final nonce = _extractQuotedValue(message, 'nonce');
      final realm = _extractQuotedValue(message, 'realm');
      final qop = _extractQuotedValue(message, 'qop');

      sipLog('[SIP] 401 challenge for $cseqMethod: realm=$realm, nonce=$nonce, qop=$qop');

      if (nonce != null && realm != null) {
        if (cseqMethod == 'INVITE') {
          // Re-send INVITE with auth credentials
          final callId = _getHeaderValue(message, 'Call-ID')?.trim();
          if (callId != null) {
            await _resendInviteWithAuth(callId, nonce, realm, qop);
          }
        } else {
          // REGISTER auth
          _cseq++;
          _branch = _generateBranch();
          final authMessage =
              _buildRegisterMessage(nonce: nonce, realm: realm, qop: qop);
          _sendMessage(authMessage);
        }
      }
    } else if (statusLine.contains(' 200 ')) {
      if (cseqMethod == 'REGISTER') {
        _isRegistered = true;
        sipLog('[SIP] Registered successfully as $_username@$_server');
        onRegistrationStateChanged?.call(true);
        _startKeepAlive();
      } else if (cseqMethod == 'INVITE') {
        final callId = _getHeaderValue(message, 'Call-ID')?.trim();
        if (callId != null) {
          // Always ACK the 200 OK (required by SIP)
          await _sendAck(message, callId);

          if (_endedCallIds.contains(callId)) {
            // Late 200 OK for cancelled call — ACK then BYE
            sipLog('[SIP] Late 200 OK for cancelled call $callId — sending BYE');
            await _sendBye(callId);
          } else if (_holdPendingCallIds.remove(callId)) {
            // 200 OK for our hold re-INVITE — just ACK, no RTP setup
            final call = _activeCalls[callId];
            if (call != null) {
              call.isOnHold = true;
              onCallStateChanged?.call(callId, 'HELD');
            }
            sipLog('[SIP] Hold confirmed for $callId');
          } else if (_activeCalls.containsKey(callId)) {
            final call = _activeCalls[callId]!;
            if (!call.isConfirmed) {
              // Initial INVITE 200 OK
              call.isConfirmed = true;
              await _setupRtpFromSdp(message);
              onCallStateChanged?.call(callId, 'CONFIRMED');
            } else {
              // Unhold re-INVITE 200 OK — resume audio
              call.isOnHold = false;
              await _setupRtpFromSdp(message);
              onCallStateChanged?.call(callId, 'RESUMED');
              sipLog('[SIP] Unhold confirmed for $callId');
            }
          }
        }
      } else if (cseqMethod == 'BYE') {
        final callId = _getHeaderValue(message, 'Call-ID')?.trim();
        if (callId != null) {
          onCallStateChanged?.call(callId, 'ENDED');
        }
      }
    } else if (statusLine.contains(' 100 ')) {
      // 100 Trying — ignore
    } else if (statusLine.contains(' 180 ')) {
      final callId = _getHeaderValue(message, 'Call-ID')?.trim();
      if (callId != null) {
        onCallStateChanged?.call(callId, 'RINGING');
      }
    } else if (statusLine.contains(' 403 ')) {
      if (cseqMethod == 'REGISTER') {
        sipLog('[SIP] Registration FORBIDDEN — check credentials');
        _isRegistered = false;
        onRegistrationStateChanged?.call(false);
        onError?.call('Registration forbidden — wrong credentials');
      }
    } else if (statusLine.contains(' 487 ')) {
      // 487 Request Terminated — response to our CANCEL; ACK it
      await _sendNon2xxAck(message);
      final callId = _getHeaderValue(message, 'Call-ID')?.trim();
      if (callId != null) {
        _activeCalls.remove(callId);
        onCallStateChanged?.call(callId, 'ENDED');
      }
    } else if (statusLine.contains(' 486 ') ||
        statusLine.contains(' 603 ')) {
      // Busy / Decline — ACK the final response
      await _sendNon2xxAck(message);
      final callId = _getHeaderValue(message, 'Call-ID')?.trim();
      if (callId != null) {
        _activeCalls.remove(callId);
        onCallStateChanged?.call(callId, 'DECLINED');
      }
    }
  }

  // ── SIP Requests ──────────────────────────────────────────

  void _handleRequest(String statusLine, String message) {
    if (statusLine.startsWith('INVITE')) {
      _handleIncomingInvite(message);
    } else if (statusLine.startsWith('BYE')) {
      _handleBye(message);
    } else if (statusLine.startsWith('CANCEL')) {
      _handleCancel(message);
    } else if (statusLine.startsWith('OPTIONS')) {
      _sendSimpleResponse(message, 200, 'OK', includeAllow: true);
    } else if (statusLine.startsWith('NOTIFY')) {
      _sendSimpleResponse(message, 200, 'OK');
    } else if (statusLine.startsWith('ACK')) {
      // ACK for our 200 OK to incoming INVITE — dialog established
      final callId = _getHeaderValue(message, 'Call-ID')?.trim();
      if (callId != null) {
        onCallStateChanged?.call(callId, 'CONFIRMED');
      }
    }
  }

  // ── Incoming INVITE ───────────────────────────────────────

  void _handleIncomingInvite(String message) {
    final fromLine = _getHeaderValue(message, 'From');
    final callId = _getHeaderValue(message, 'Call-ID')?.trim();

    if (fromLine == null || callId == null) return;

    // If this call is already active, it's a re-INVITE (possibly hold/unhold)
    if (_activeCalls.containsKey(callId)) {
      _handleReInvite(message, callId);
      return;
    }

    // Extract phone number from From header
    String callerNumber = fromLine;
    final sipUriMatch = RegExp(r'<sip:([^@>]+)@').firstMatch(fromLine);
    if (sipUriMatch != null) {
      callerNumber = sipUriMatch.group(1) ?? fromLine;
    } else {
      final simpleMatch = RegExp(r'sip:([^@;]+)@').firstMatch(fromLine);
      if (simpleMatch != null) {
        callerNumber = simpleMatch.group(1) ?? fromLine;
      }
    }

    // Generate a local tag for this dialog — MUST be consistent across 180 and 200
    final localTag = _generateTag();

    // Store pending invite with its tag
    _pendingInvites[callId] = _PendingInvite(
      rawMessage: message,
      localTag: localTag,
    );

    onIncomingCall?.call(callerNumber, callId);

    // Send 180 Ringing with our dialog tag
    _sendResponseWithTag(message, 180, 'Ringing', localTag);
  }

  // ── BYE ───────────────────────────────────────────────────

  void _handleBye(String message) async {
    final callId = _getHeaderValue(message, 'Call-ID')?.trim();

    // Always respond 200 OK to BYE
    _sendSimpleResponse(message, 200, 'OK');

    if (callId != null) {
      _endedCallIds.add(callId);
      _activeCalls.remove(callId);
      _pendingInvites.remove(callId);
    }

    // Stop audio
    _cleanupAudio();

    if (callId != null) {
      onCallStateChanged?.call(callId, 'ENDED');
    }
  }

  // ── CANCEL ────────────────────────────────────────────────

  void _handleCancel(String message) {
    final callId = _getHeaderValue(message, 'Call-ID')?.trim();

    // Respond 200 OK to CANCEL
    _sendSimpleResponse(message, 200, 'OK');

    // Also send 487 Request Terminated for the original INVITE
    if (callId != null) {
      final pending = _pendingInvites[callId];
      if (pending != null) {
        _sendResponseWithTag(
            pending.rawMessage, 487, 'Request Terminated', pending.localTag);
      }
      _pendingInvites.remove(callId);
      _activeCalls.remove(callId);
      onCallStateChanged?.call(callId, 'CANCELED');
    }
  }

  // ── Response builders ─────────────────────────────────────

  /// Send a simple response (200 OK to OPTIONS, NOTIFY, BYE, etc.)
  void _sendSimpleResponse(String request, int code, String reason,
      {bool includeAllow = false}) {
    try {
      final lines = request.split('\n');
      final via = _findHeader(lines, 'Via:');
      final from = _findHeader(lines, 'From:');
      final to = _findHeader(lines, 'To:');
      final callIdLine = _findHeader(lines, 'Call-ID:');
      final cseq = _findHeader(lines, 'CSeq:');

      final buf = StringBuffer();
      _w(buf, 'SIP/2.0 $code $reason');
      _w(buf, 'Via: $via');
      _w(buf, 'From: $from');

      // Add tag to To if not present
      if (!to.contains('tag=')) {
        _w(buf, 'To: $to;tag=${_generateTag()}');
      } else {
        _w(buf, 'To: $to');
      }

      _w(buf, 'Call-ID: $callIdLine');
      _w(buf, 'CSeq: $cseq');
      _w(buf, 'User-Agent: IQ-SIP');

      if (includeAllow) {
        _w(buf, 'Allow: INVITE, ACK, CANCEL, BYE, NOTIFY, REFER, OPTIONS');
      }

      _w(buf, 'Content-Length: 0');
      _blank(buf);

      _sendMessage(buf.toString());
    } catch (e) {
      onError?.call('Error sending $code response: $e');
    }
  }

  /// Send response with a specific local tag (for INVITE dialog consistency)
  void _sendResponseWithTag(
      String request, int code, String reason, String localTag) {
    try {
      final lines = request.split('\n');
      final via = _findHeader(lines, 'Via:');
      final from = _findHeader(lines, 'From:');
      final to = _findHeader(lines, 'To:');
      final callIdLine = _findHeader(lines, 'Call-ID:');
      final cseq = _findHeader(lines, 'CSeq:');

      // Strip any existing tag from To so we use ours consistently
      final toBase = _stripTag(to);

      final buf = StringBuffer();
      _w(buf, 'SIP/2.0 $code $reason');
      _w(buf, 'Via: $via');
      _w(buf, 'From: $from');
      _w(buf, 'To: $toBase;tag=$localTag');
      _w(buf, 'Call-ID: $callIdLine');
      _w(buf, 'CSeq: $cseq');
      _w(buf, 'Contact: <sip:$_username@$_localIP:$_localPort>');
      _w(buf, 'User-Agent: IQ-SIP');
      _w(buf, 'Content-Length: 0');
      _blank(buf);

      _sendMessage(buf.toString());
    } catch (e) {
      onError?.call('Error sending $code tagged response: $e');
    }
  }

  // ── Answer Call ───────────────────────────────────────────

  Future<void> answerCall(String callId) async {
    sipLog('[SIP] answerCall called for callId: $callId');
    sipLog('[SIP] Pending invites: ${_pendingInvites.keys.toList()}');
    final pending = _pendingInvites[callId];
    if (pending == null) {
      onError?.call('No pending invite for callId: $callId');
      sipLog('[SIP] ERROR: No pending invite found!');
      return;
    }

    try {
      final message = pending.rawMessage;
      final localTag = pending.localTag;
      final lines = message.split('\n');
      final via = _findHeader(lines, 'Via:');
      final from = _findHeader(lines, 'From:');
      final to = _findHeader(lines, 'To:');
      final callIdLine = _findHeader(lines, 'Call-ID:');
      final cseq = _findHeader(lines, 'CSeq:');

      // Extract remote RTP endpoint from INVITE SDP
      String? remoteHost;
      int? remotePort;
      final sdpStart = message.indexOf('\n\n');
      if (sdpStart != -1) {
        final remoteSdp = message.substring(sdpStart + 2);
        final sdpInfo = _parseSdp(remoteSdp);
        remoteHost = sdpInfo['host'];
        remotePort = int.tryParse(sdpInfo['port'] ?? '');
      }

      // Initialize RTP audio
      await onRtpInitialize?.call();

      if (remoteHost != null && remotePort != null) {
        onRtpSetRemoteEndpoint?.call(remoteHost, remotePort);
      }

      final rtpPort = onRtpGetLocalPort?.call();
      if (rtpPort == null) {
        throw Exception('RTP socket not initialized');
      }

      // Build 200 OK with SDP
      final sdp = _buildSDP(rtpPort);
      final sdpBytes = utf8.encode(sdp);
      final toBase = _stripTag(to);

      final buf = StringBuffer();
      _w(buf, 'SIP/2.0 200 OK');
      _w(buf, 'Via: $via');
      _w(buf, 'From: $from');
      _w(buf, 'To: $toBase;tag=$localTag'); // Same tag as 180 Ringing!
      _w(buf, 'Call-ID: $callIdLine');
      _w(buf, 'CSeq: $cseq');
      _w(buf, 'Contact: <sip:$_username@$_localIP:$_localPort>');
      _w(buf, 'User-Agent: IQ-SIP');
      _w(buf, 'Allow: INVITE, ACK, CANCEL, BYE, NOTIFY, REFER, OPTIONS');
      _w(buf, 'Content-Type: application/sdp');
      _w(buf, 'Content-Length: ${sdpBytes.length}');
      _blank(buf);
      buf.write(sdp);

      await _sendMessage(buf.toString());

      // Extract remote tag from From header
      final remoteTag = _extractTag(from);

      // Strip tags from headers for clean storage
      final fromNoTag = _stripTag(from);

      // Move from pending to active
      sipLog('[SIP] 200 OK sent for $callId, RTP port: $rtpPort');
      sipLog('[SIP] Remote RTP: $remoteHost:$remotePort');
      _pendingInvites.remove(callId);
      final call = SipCall(
        callId: callId,
        fromHeader: fromNoTag, // Remote party (without tag)
        toHeader: toBase,      // Us (without tag)
        localTag: localTag,
        remoteTag: remoteTag,
        isIncoming: true,
      );
      call.isConfirmed = true;
      call.remoteRtpHost = remoteHost;
      call.remoteRtpPort = remotePort;
      _activeCalls[callId] = call;

      // Send initial silence to open NAT/firewall pinhole
      try {
        final silence = Uint8List(160);
        for (int i = 0; i < 160; i++) {
          silence[i] = 0xD5; // PCMA silence
        }
        onRtpSendAudio?.call(silence, 8);
      } catch (_) {}

      // Start microphone capture
      try {
        await onMicrophoneStart?.call();
      } catch (e) {
        onError?.call('Microphone start failed: $e');
      }
    } catch (e) {
      onError?.call('Failed to answer call: $e');
    }
  }

  // ── Hangup ────────────────────────────────────────────────

  Future<void> hangupCall(String callId) async {
    // Mark call as ended so late 200 OKs trigger BYE instead of audio setup
    _endedCallIds.add(callId);

    // Stop audio
    _cleanupAudio();

    // If pending incoming (not answered yet), reject with 486 Busy Here
    final pending = _pendingInvites[callId];
    if (pending != null) {
      _sendResponseWithTag(
          pending.rawMessage, 486, 'Busy Here', pending.localTag);
      _pendingInvites.remove(callId);
      return;
    }

    final call = _activeCalls[callId];
    if (call == null) return;

    // Outgoing call still ringing → send CANCEL (not BYE)
    // Don't remove from _activeCalls here — the 487 response handler will do it
    if (!call.isIncoming && !call.isConfirmed) {
      await _sendCancel(call);
      return;
    }

    // Confirmed call → send BYE
    await _sendBye(callId);
  }

  // ── Hold / Unhold ──────────────────────────────────────────

  /// Put an active call on hold by sending re-INVITE with a=sendonly.
  Future<void> holdCall(String callId) async {
    final call = _activeCalls[callId];
    if (call == null) {
      onError?.call('No active call to hold: $callId');
      return;
    }

    try {
      // Stop microphone — don't send audio to a held call
      onMicrophoneStop?.call();

      _holdPendingCallIds.add(callId);
      _cseq++;

      String requestUri;
      String fromLine;
      String toLine;

      if (call.isIncoming) {
        requestUri = _extractSipUri(call.fromHeader) ?? 'sip:$_server';
        fromLine = '${call.toHeader};tag=${call.localTag}';
        toLine =
            '${call.fromHeader}${call.remoteTag != null ? ";tag=${call.remoteTag}" : ""}';
      } else {
        requestUri = _extractSipUri(call.toHeader) ?? 'sip:$_server';
        fromLine = '${call.fromHeader};tag=${call.localTag}';
        toLine =
            '${call.toHeader}${call.remoteTag != null ? ";tag=${call.remoteTag}" : ""}';
      }

      final rtpPort = onRtpGetLocalPort?.call() ?? 0;
      final sdp = _buildSDP(rtpPort, direction: 'sendonly');
      final sdpBytes = utf8.encode(sdp);

      final buf = StringBuffer();
      _w(buf, 'INVITE $requestUri SIP/2.0');
      _w(buf,
          'Via: SIP/2.0/UDP $_localIP:$_localPort;branch=${_generateBranch()}');
      _w(buf, 'From: $fromLine');
      _w(buf, 'To: $toLine');
      _w(buf, 'Call-ID: $callId');
      _w(buf, 'CSeq: $_cseq INVITE');
      _w(buf, 'Contact: <sip:$_username@$_localIP:$_localPort>');
      _w(buf, 'Max-Forwards: 70');
      _w(buf, 'User-Agent: IQ-SIP');
      _w(buf, 'Content-Type: application/sdp');
      _w(buf, 'Content-Length: ${sdpBytes.length}');
      _blank(buf);
      buf.write(sdp);

      await _sendMessage(buf.toString());
      sipLog('[SIP] Hold re-INVITE sent for $callId');
    } catch (e) {
      _holdPendingCallIds.remove(callId);
      onError?.call('Failed to hold call: $e');
    }
  }

  /// Resume a held call by sending re-INVITE with a=sendrecv.
  Future<void> unholdCall(String callId) async {
    final call = _activeCalls[callId];
    if (call == null) {
      onError?.call('No active call to unhold: $callId');
      return;
    }

    try {
      // Re-initialize RTP to get a valid port for the SDP
      await onRtpInitialize?.call();
      final rtpPort = onRtpGetLocalPort?.call();
      if (rtpPort == null) {
        onError?.call('Failed to initialize RTP for unhold');
        return;
      }

      _cseq++;

      String requestUri;
      String fromLine;
      String toLine;

      if (call.isIncoming) {
        requestUri = _extractSipUri(call.fromHeader) ?? 'sip:$_server';
        fromLine = '${call.toHeader};tag=${call.localTag}';
        toLine =
            '${call.fromHeader}${call.remoteTag != null ? ";tag=${call.remoteTag}" : ""}';
      } else {
        requestUri = _extractSipUri(call.toHeader) ?? 'sip:$_server';
        fromLine = '${call.fromHeader};tag=${call.localTag}';
        toLine =
            '${call.toHeader}${call.remoteTag != null ? ";tag=${call.remoteTag}" : ""}';
      }

      final sdp = _buildSDP(rtpPort, direction: 'sendrecv');
      final sdpBytes = utf8.encode(sdp);

      final buf = StringBuffer();
      _w(buf, 'INVITE $requestUri SIP/2.0');
      _w(buf,
          'Via: SIP/2.0/UDP $_localIP:$_localPort;branch=${_generateBranch()}');
      _w(buf, 'From: $fromLine');
      _w(buf, 'To: $toLine');
      _w(buf, 'Call-ID: $callId');
      _w(buf, 'CSeq: $_cseq INVITE');
      _w(buf, 'Contact: <sip:$_username@$_localIP:$_localPort>');
      _w(buf, 'Max-Forwards: 70');
      _w(buf, 'User-Agent: IQ-SIP');
      _w(buf, 'Content-Type: application/sdp');
      _w(buf, 'Content-Length: ${sdpBytes.length}');
      _blank(buf);
      buf.write(sdp);

      await _sendMessage(buf.toString());
      sipLog('[SIP] Unhold re-INVITE sent for $callId');
    } catch (e) {
      onError?.call('Failed to unhold call: $e');
    }
  }

  /// Handle incoming re-INVITE (remote hold/unhold or media update).
  void _handleReInvite(String message, String callId) {
    final call = _activeCalls[callId];
    if (call == null) return;

    try {
      // Parse SDP direction
      String remoteDirection = 'sendrecv';
      final sdpStart = message.indexOf('\n\n');
      if (sdpStart != -1) {
        final remoteSdp = message.substring(sdpStart + 2);
        final sdpInfo = _parseSdp(remoteSdp);
        remoteDirection = sdpInfo['direction'] ?? 'sendrecv';
      }

      // Determine our response direction and update hold state
      String responseDirection;
      if (remoteDirection == 'sendonly') {
        // Remote is putting us on hold
        responseDirection = 'recvonly';
        call.isRemoteHold = true;
        onMicrophoneStop?.call();
      } else if (remoteDirection == 'inactive') {
        responseDirection = 'inactive';
        call.isRemoteHold = true;
        onMicrophoneStop?.call();
      } else {
        // Remote is resuming (sendrecv or recvonly)
        responseDirection = 'sendrecv';
        call.isRemoteHold = false;
      }

      // Build 200 OK with SDP
      final rtpPort = onRtpGetLocalPort?.call() ?? 0;
      final sdp = _buildSDP(rtpPort, direction: responseDirection);
      final sdpBytes = utf8.encode(sdp);

      final lines = message.split('\n');
      final via = _findHeader(lines, 'Via:');
      final from = _findHeader(lines, 'From:');
      final to = _findHeader(lines, 'To:');
      final callIdLine = _findHeader(lines, 'Call-ID:');
      final cseq = _findHeader(lines, 'CSeq:');

      // Add our tag to To if not present
      final toWithTag = to.contains('tag=')
          ? to
          : '$to;tag=${call.localTag}';

      final buf = StringBuffer();
      _w(buf, 'SIP/2.0 200 OK');
      _w(buf, 'Via: $via');
      _w(buf, 'From: $from');
      _w(buf, 'To: $toWithTag');
      _w(buf, 'Call-ID: $callIdLine');
      _w(buf, 'CSeq: $cseq');
      _w(buf, 'Contact: <sip:$_username@$_localIP:$_localPort>');
      _w(buf, 'User-Agent: IQ-SIP');
      _w(buf, 'Content-Type: application/sdp');
      _w(buf, 'Content-Length: ${sdpBytes.length}');
      _blank(buf);
      buf.write(sdp);

      _sendMessage(buf.toString());

      // Notify state change
      if (call.isRemoteHold) {
        onCallStateChanged?.call(callId, 'REMOTE_HELD');
        sipLog('[SIP] Remote hold for $callId');
      } else {
        onCallStateChanged?.call(callId, 'REMOTE_RESUMED');
        // Restart mic when remote unhold
        onMicrophoneStart?.call();
        sipLog('[SIP] Remote resumed for $callId');
      }
    } catch (e) {
      // If re-INVITE handling fails, still try to respond
      _sendSimpleResponse(message, 200, 'OK');
      onError?.call('Error handling re-INVITE: $e');
    }
  }

  /// Get a map of all active calls (read-only snapshot).
  Map<String, SipCall> get activeCalls => Map.unmodifiable(_activeCalls);

  /// Send CANCEL for a pending outgoing INVITE.
  Future<void> _sendCancel(SipCall call) async {
    try {
      final requestUri =
          _extractSipUri(call.toHeader) ?? 'sip:$_server';

      final buf = StringBuffer();
      _w(buf, 'CANCEL $requestUri SIP/2.0');
      // CANCEL must reuse the same branch as the INVITE it cancels
      _w(buf,
          'Via: SIP/2.0/UDP $_localIP:$_localPort;branch=${call.inviteBranch}');
      _w(buf, 'From: "$_displayName" ${call.fromHeader};tag=${call.localTag}');
      _w(buf, 'To: ${call.toHeader}');
      _w(buf, 'Call-ID: ${call.callId}');
      // CANCEL must use the same CSeq number as the INVITE, with method CANCEL
      _w(buf, 'CSeq: ${call.inviteCSeq} CANCEL');
      _w(buf, 'Max-Forwards: 70');
      _w(buf, 'User-Agent: IQ-SIP');
      _w(buf, 'Content-Length: 0');
      _blank(buf);

      await _sendMessage(buf.toString());
    } catch (e) {
      onError?.call('Failed to send CANCEL: $e');
    }
  }

  /// Send BYE for a confirmed call.
  Future<void> _sendBye(String callId) async {
    final call = _activeCalls[callId];
    if (call == null) return;

    try {
      _cseq++;

      String requestUri;
      String fromLine;
      String toLine;

      if (call.isIncoming) {
        requestUri = _extractSipUri(call.fromHeader) ?? 'sip:$_server';
        fromLine = '${call.toHeader};tag=${call.localTag}';
        toLine =
            '${call.fromHeader}${call.remoteTag != null ? ";tag=${call.remoteTag}" : ""}';
      } else {
        requestUri = _extractSipUri(call.toHeader) ?? 'sip:$_server';
        fromLine = '${call.fromHeader};tag=${call.localTag}';
        toLine =
            '${call.toHeader}${call.remoteTag != null ? ";tag=${call.remoteTag}" : ""}';
      }

      final buf = StringBuffer();
      _w(buf, 'BYE $requestUri SIP/2.0');
      _w(buf,
          'Via: SIP/2.0/UDP $_localIP:$_localPort;branch=${_generateBranch()}');
      _w(buf, 'From: $fromLine');
      _w(buf, 'To: $toLine');
      _w(buf, 'Call-ID: $callId');
      _w(buf, 'CSeq: $_cseq BYE');
      _w(buf, 'Contact: <sip:$_username@$_localIP:$_localPort>');
      _w(buf, 'Max-Forwards: 70');
      _w(buf, 'User-Agent: IQ-SIP');
      _w(buf, 'Content-Length: 0');
      _blank(buf);

      await _sendMessage(buf.toString());
    } catch (e) {
      onError?.call('Failed to send BYE: $e');
    } finally {
      _activeCalls.remove(callId);
    }
  }

  // ── ACK ─────────────────────────────────────────────────────

  /// ACK for 2xx responses (initial INVITE and re-INVITE).
  Future<void> _sendAck(String responseMessage, String callId) async {
    try {
      final call = _activeCalls[callId];
      if (call == null) return;

      // Extract remote tag from 200 OK To header
      final toLine = _getHeaderValue(responseMessage, 'To') ?? '';
      final toTag = _extractTag(toLine);
      if (toTag.isNotEmpty) {
        call.remoteTag = toTag;
      }

      // Direction-aware From/To/RequestURI (same as BYE)
      String requestUri;
      String fromLine;
      String toHeaderLine;

      if (call.isIncoming) {
        requestUri = _extractSipUri(call.fromHeader) ?? 'sip:$_server';
        fromLine = '${call.toHeader};tag=${call.localTag}';
        toHeaderLine =
            '${call.fromHeader}${call.remoteTag != null ? ";tag=${call.remoteTag}" : ""}';
      } else {
        requestUri = _extractSipUri(call.toHeader) ?? 'sip:$_server';
        fromLine = '${call.fromHeader};tag=${call.localTag}';
        toHeaderLine =
            '${call.toHeader}${call.remoteTag != null ? ";tag=${call.remoteTag}" : ""}';
      }

      final buf = StringBuffer();
      _w(buf, 'ACK $requestUri SIP/2.0');
      _w(buf,
          'Via: SIP/2.0/UDP $_localIP:$_localPort;branch=${_generateBranch()}');
      _w(buf, 'From: $fromLine');
      _w(buf, 'To: $toHeaderLine');
      _w(buf, 'Call-ID: $callId');
      _w(buf, 'CSeq: $_cseq ACK');
      _w(buf, 'Max-Forwards: 70');
      _w(buf, 'User-Agent: IQ-SIP');
      _w(buf, 'Content-Length: 0');
      _blank(buf);

      await _sendMessage(buf.toString());
    } catch (e) {
      onError?.call('Failed to send ACK: $e');
    }
  }

  /// ACK for non-2xx final responses (487, 486, 603, etc.).
  /// Constructed from the response headers directly.
  Future<void> _sendNon2xxAck(String responseMessage) async {
    try {
      final from = _getHeaderValue(responseMessage, 'From') ?? '';
      final to = _getHeaderValue(responseMessage, 'To') ?? '';
      final callId = _getHeaderValue(responseMessage, 'Call-ID')?.trim() ?? '';
      final cseqLine = _getHeaderValue(responseMessage, 'CSeq') ?? '';
      final cseqNum = cseqLine.split(' ').first.trim();
      final viaHeader = _getHeaderValue(responseMessage, 'Via') ?? '';
      final branchMatch = RegExp(r'branch=([^\s;,]+)').firstMatch(viaHeader);
      final branch = branchMatch?.group(1) ?? _generateBranch();
      final requestUri = _extractSipUri(to) ?? 'sip:$_server';

      final buf = StringBuffer();
      _w(buf, 'ACK $requestUri SIP/2.0');
      _w(buf, 'Via: SIP/2.0/UDP $_localIP:$_localPort;branch=$branch');
      _w(buf, 'From: $from');
      _w(buf, 'To: $to');
      _w(buf, 'Call-ID: $callId');
      _w(buf, 'CSeq: $cseqNum ACK');
      _w(buf, 'Max-Forwards: 70');
      _w(buf, 'User-Agent: IQ-SIP');
      _w(buf, 'Content-Length: 0');
      _blank(buf);

      await _sendMessage(buf.toString());
    } catch (e) {
      onError?.call('Failed to send ACK: $e');
    }
  }

  // ── SDP ───────────────────────────────────────────────────

  /// Build SDP with proper \r\n line endings.
  /// [direction] can be 'sendrecv', 'sendonly', 'recvonly', or 'inactive'.
  String _buildSDP(int rtpPort, {String direction = 'sendrecv'}) {
    final sessionId = DateTime.now().millisecondsSinceEpoch;
    final lines = [
      'v=0',
      'o=- $sessionId $sessionId IN IP4 $_localIP',
      's=IQ-SIP',
      'c=IN IP4 $_localIP',
      't=0 0',
      'm=audio $rtpPort RTP/AVP 8 0 101',
      'a=rtpmap:8 PCMA/8000',
      'a=rtpmap:0 PCMU/8000',
      'a=rtpmap:101 telephone-event/8000',
      'a=fmtp:101 0-15',
      'a=ptime:20',
      'a=$direction',
    ];
    return '${lines.join('\r\n')}\r\n';
  }

  /// Parse SDP to extract host, port, and media direction
  Map<String, String?> _parseSdp(String sdp) {
    String? host;
    String? port;
    String? direction;
    for (final line in sdp.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('c=IN IP4 ')) {
        host = trimmed.substring('c=IN IP4 '.length).trim();
      }
      if (trimmed.startsWith('m=audio ')) {
        final parts = trimmed.split(' ');
        if (parts.length >= 2) port = parts[1];
      }
      if (trimmed == 'a=sendonly' ||
          trimmed == 'a=recvonly' ||
          trimmed == 'a=sendrecv' ||
          trimmed == 'a=inactive') {
        direction = trimmed.substring(2); // strip 'a='
      }
    }
    return {'host': host, 'port': port, 'direction': direction};
  }

  /// Setup RTP from SDP in a 200 OK response.
  /// Also stores remote RTP endpoint in the SipCall for hold/resume.
  Future<void> _setupRtpFromSdp(String message) async {
    try {
      final sdpStart = message.indexOf('\n\n');
      if (sdpStart == -1) return;
      final remoteSdp = message.substring(sdpStart + 2);
      final sdpInfo = _parseSdp(remoteSdp);
      final remoteHost = sdpInfo['host'];
      final remotePort = int.tryParse(sdpInfo['port'] ?? '');

      // Store remote RTP endpoint in the call for hold/resume
      final callId = _getHeaderValue(message, 'Call-ID')?.trim();
      if (callId != null) {
        final call = _activeCalls[callId];
        if (call != null && remoteHost != null && remotePort != null) {
          call.remoteRtpHost = remoteHost;
          call.remoteRtpPort = remotePort;
        }
      }

      // Only initialize RTP if not already active (makeCall already initialized)
      if (!(onRtpIsActive?.call() ?? false)) {
        await onRtpInitialize?.call();
      }
      if (remoteHost != null && remotePort != null) {
        onRtpSetRemoteEndpoint?.call(remoteHost, remotePort);
      }

      // Start microphone capture (sends PCMA via RTP internally)
      await onMicrophoneStart?.call();
    } catch (e) {
      onError?.call('RTP setup failed: $e');
    }
  }

  // ── Make outgoing call ────────────────────────────────────

  Future<void> makeCall(String destination) async {
    if (!_isRegistered) throw Exception('Not registered');

    try {
      final outCallId = _generateCallId();
      final outBranch = _generateBranch();
      final outTag = _generateTag();
      _cseq++;

      final uri = 'sip:$destination@$_server';
      final from = '<sip:$_username@$_server>';
      final to = '<sip:$destination@$_server>';

      // Initialize RTP
      await onRtpInitialize?.call();
      final rtpPort = onRtpGetLocalPort?.call();
      if (rtpPort == null) throw Exception('Failed to initialize RTP');

      final sdp = _buildSDP(rtpPort);
      final sdpBytes = utf8.encode(sdp);

      final buf = StringBuffer();
      _w(buf, 'INVITE $uri SIP/2.0');
      _w(buf,
          'Via: SIP/2.0/UDP $_localIP:$_localPort;branch=$outBranch');
      _w(buf, 'From: "$_displayName" $from;tag=$outTag');
      _w(buf, 'To: $to');
      _w(buf, 'Call-ID: $outCallId');
      _w(buf, 'CSeq: $_cseq INVITE');
      _w(buf, 'Contact: <sip:$_username@$_localIP:$_localPort>');
      _w(buf, 'Max-Forwards: 70');
      _w(buf, 'User-Agent: IQ-SIP');
      _w(buf, 'Allow: INVITE, ACK, CANCEL, BYE, NOTIFY, REFER, OPTIONS');
      _w(buf, 'Content-Type: application/sdp');
      _w(buf, 'Content-Length: ${sdpBytes.length}');
      _blank(buf);
      buf.write(sdp);

      await _sendMessage(buf.toString());

      // Store call info for tracking
      _activeCalls[outCallId] = SipCall(
        callId: outCallId,
        fromHeader: from,
        toHeader: to,
        localTag: outTag,
        isIncoming: false,
        inviteBranch: outBranch,
        inviteCSeq: _cseq,
      );

      onCallStateChanged?.call(outCallId, 'CALLING');
    } catch (e) {
      onError?.call('Failed to make call: $e');
      rethrow;
    }
  }

  // ── Re-send INVITE with auth ─────────────────────────────

  Future<void> _resendInviteWithAuth(
      String callId, String nonce, String realm, String? qop) async {
    final call = _activeCalls[callId];
    if (call == null) {
      sipLog('[SIP] No active call found for INVITE auth: $callId');
      return;
    }

    try {
      _cseq++;
      final newBranch = _generateBranch();

      final uri = _extractSipUri(call.toHeader) ?? 'sip:${call.toHeader}@$_server';
      final rtpPort = onRtpGetLocalPort?.call();
      if (rtpPort == null) return;

      final sdp = _buildSDP(rtpPort);
      final sdpBytes = utf8.encode(sdp);
      final authHeader = _buildAuthHeader('INVITE', uri, nonce, realm, qop: qop);

      final buf = StringBuffer();
      _w(buf, 'INVITE $uri SIP/2.0');
      _w(buf, 'Via: SIP/2.0/UDP $_localIP:$_localPort;branch=$newBranch');
      _w(buf, 'From: "$_displayName" ${call.fromHeader};tag=${call.localTag}');
      _w(buf, 'To: ${call.toHeader}');
      _w(buf, 'Call-ID: $callId');
      _w(buf, 'CSeq: $_cseq INVITE');
      _w(buf, 'Contact: <sip:$_username@$_localIP:$_localPort>');
      _w(buf, 'Max-Forwards: 70');
      _w(buf, 'User-Agent: IQ-SIP');
      _w(buf, 'Authorization: $authHeader');
      _w(buf, 'Allow: INVITE, ACK, CANCEL, BYE, NOTIFY, REFER, OPTIONS');
      _w(buf, 'Content-Type: application/sdp');
      _w(buf, 'Content-Length: ${sdpBytes.length}');
      _blank(buf);
      buf.write(sdp);

      await _sendMessage(buf.toString());
      // Update stored branch/CSeq so CANCEL matches the authenticated INVITE
      call.inviteBranch = newBranch;
      call.inviteCSeq = _cseq;
      sipLog('[SIP] Re-sent INVITE with auth for $callId');
    } catch (e) {
      onError?.call('Failed to resend INVITE with auth: $e');
    }
  }

  // ── Keep-alive & disconnect ───────────────────────────────

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(minutes: 25), (_) {
      if (_isRegistered) {
        _cseq++;
        _register();
      }
    });
  }

  Future<void> disconnect() async {
    _keepAliveTimer?.cancel();
    _cleanupAudio();
    _socket?.close();
    _isRegistered = false;
    _activeCalls.clear();
    _pendingInvites.clear();
    _endedCallIds.clear();
    _holdPendingCallIds.clear();
    onRegistrationStateChanged?.call(false);
  }

  // ── Audio cleanup ─────────────────────────────────────────

  void _cleanupAudio() {
    try {
      onAudioCleanup?.call();
    } catch (_) {}
  }

  // ── UDP send ──────────────────────────────────────────────

  Future<void> _sendMessage(String message) async {
    if (_socket == null || _serverAddress == null) {
      throw Exception('Socket not initialized');
    }
    // Log first line of every outgoing message
    final firstLine = message.split('\r\n').first;
    sipLog('[SIP] >>> $firstLine');
    _socket!.send(utf8.encode(message), _serverAddress!, _port);
  }

  // ── Header parsing helpers ────────────────────────────────

  /// Get header value from a normalized (no \r) SIP message
  String? _getHeaderValue(String message, String headerName) {
    for (final line in message.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('$headerName:')) {
        return trimmed.substring(headerName.length + 1).trim();
      }
    }
    return null;
  }

  /// Find a header line by prefix, return value part only (trimmed)
  String _findHeader(List<String> lines, String prefix) {
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith(prefix)) {
        return trimmed.substring(prefix.length).trim();
      }
    }
    return '';
  }

  /// Get the method from the CSeq header (e.g., "REGISTER", "INVITE")
  String? _getCSeqMethod(String message) {
    final cseq = _getHeaderValue(message, 'CSeq');
    if (cseq == null) return null;
    final parts = cseq.trim().split(' ');
    return parts.length >= 2 ? parts[1] : null;
  }

  /// Extract quoted value (e.g., nonce="...", realm="...")
  /// Also handles unquoted values (e.g., qop=auth)
  String? _extractQuotedValue(String message, String key) {
    // Try quoted first
    final quotedPattern = RegExp('$key="([^"]+)"');
    final quotedMatch = quotedPattern.firstMatch(message);
    if (quotedMatch != null) return quotedMatch.group(1);

    // Try unquoted (e.g., qop=auth)
    final unquotedPattern = RegExp('$key=([^,\\s]+)');
    final unquotedMatch = unquotedPattern.firstMatch(message);
    return unquotedMatch?.group(1);
  }

  /// Extract tag= value from a header line
  String _extractTag(String headerValue) {
    final match = RegExp(r'tag=([^\s;>]+)').firstMatch(headerValue);
    return match?.group(1) ?? '';
  }

  /// Strip tag= parameter from a header value
  String _stripTag(String headerValue) {
    return headerValue.replaceAll(RegExp(r';?\s*tag=[^\s;>]+'), '').trim();
  }

  /// Extract SIP URI from a header value
  String? _extractSipUri(String headerValue) {
    final match = RegExp(r'<?(sip:[^>;]+)>?').firstMatch(headerValue);
    return match?.group(1);
  }

  // ── ID generators ─────────────────────────────────────────

  String _generateCallId() => '${Random().nextInt(1000000000)}@$_localIP';
  String _generateTag() => Random().nextInt(1000000).toString();
  String _generateBranch() => 'z9hG4bK-${Random().nextInt(1000000)}';
}
