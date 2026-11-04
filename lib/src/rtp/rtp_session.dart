import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../logging.dart';
import '../net/datagram_sender.dart';

/// Plain RTP/AVP audio transport (no SRTP, no RTCP).
///
/// One socket is shared by all calls. Only packets from the focused remote
/// endpoint are delivered, so a held call's music on hold never reaches the
/// speaker. When the announced endpoint stays silent and another source
/// streams steadily, the session follows it (symmetric RTP latching, needed
/// behind NAT and after transfers).
class RtpSession {
  static final RtpSession instance = RtpSession._internal();
  RtpSession._internal();

  RawDatagramSocket? _rtpSocket;
  DatagramSender? _sender;
  int? _localRtpPort;
  String? _remoteHost;
  int? _remotePort;
  InternetAddress? _remoteAddress;

  int _sequenceNumber = Random().nextInt(0xFFFF);
  int _timestamp = Random().nextInt(0x7FFFFFFF);
  int _ssrc = Random().nextInt(0x7FFFFFFF);
  bool _marker = true;

  bool _isActive = false;
  bool get isActive => _isActive;

  int _rxCount = 0;
  int _txCount = 0;
  int _rxDropped = 0;

  /// Payload type outgoing audio is sent with (8 = PCMA, 0 = PCMU).
  int sendPayloadType = 8;

  /// Negotiated telephone-event payload type, null when not supported.
  int? dtmfPayloadType;

  /// RTP endpoints (`host:port`) of the other, held calls. Never played and
  /// never latched onto.
  Set<String> otherLegEndpoints = <String>{};

  bool _dtmfActive = false;

  // Latching state.
  DateTime _lastFromFocused = DateTime.fromMillisecondsSinceEpoch(0);
  String? _candidate;
  int _candidateCount = 0;
  DateTime _candidateSince = DateTime.fromMillisecondsSinceEpoch(0);

  /// Called with the payload of every G.711 audio packet (PT 0 or 8).
  void Function(Uint8List audioData)? onAudioReceived;

  /// Called with the payload and payload type of every accepted packet.
  void Function(Uint8List payload, int payloadType)? onRtpPayload;

  void Function(String error)? onError;

  /// Bind the RTP socket. Idempotent: an open socket is kept, because its
  /// port was advertised in SDP and rebinding mid-call would make the call
  /// silent. Call [close] first to get a fresh socket.
  Future<void> initialize({String? localIp}) async {
    if (_rtpSocket != null) {
      _isActive = true;
      return;
    }
    try {
      _rtpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // Up to one second of audio may wait for a busy socket.
      _sender = DatagramSender(_rtpSocket!, maxQueue: 50);
      _localRtpPort = _rtpSocket!.port;
      _ssrc = Random().nextInt(0x7FFFFFFF);
      _marker = true;
      sipLog('[RTP] Socket bound to port $_localRtpPort');

      _rtpSocket!.listen(
        (event) {
          if (event == RawSocketEvent.write) {
            _sender?.onWrite();
            return;
          }
          if (event != RawSocketEvent.read) return;
          try {
            _handleIncoming();
          } catch (e) {
            if (_rxCount % 100 == 0) sipLog('[RTP] Receive error: $e');
          }
        },
        onError: (Object error) => sipLog('[RTP] Socket error: $error'),
      );

      _isActive = true;
      _rxCount = 0;
      _txCount = 0;
      _rxDropped = 0;
    } catch (e) {
      sipLog('[RTP] Failed to initialize: $e');
      onError?.call('Failed to initialize RTP: $e');
      rethrow;
    }
  }

  int? get localPort => _localRtpPort;

  /// Where audio is sent (`host:port`), or null.
  String? get remoteEndpoint => _remoteHost == null || _remotePort == null
      ? null
      : '$_remoteHost:$_remotePort';

  void setRemoteEndpoint(String host, int port) {
    _remoteHost = host;
    _remotePort = port;
    _remoteAddress = InternetAddress.tryParse(host);
    if (_remoteAddress == null) {
      InternetAddress.lookup(host).then((list) {
        if (list.isNotEmpty && _remoteHost == host) _remoteAddress = list.first;
      }).catchError((Object _) {});
    }
    // Fresh focus: the announced endpoint gets its chance before latching.
    _lastFromFocused = DateTime.now();
    _candidate = null;
    _candidateCount = 0;
    _marker = true;
    sipLog('[RTP] Remote endpoint $host:$port (sending PT $sendPayloadType)');
  }

  void _handleIncoming() {
    final socket = _rtpSocket;
    if (socket == null) return;
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      _handlePacket(datagram!);
    }
  }

  void _handlePacket(Datagram datagram) {
    if (_remoteHost != null && _remotePort != null) {
      final host = datagram.address.address;
      if (host != _remoteHost || datagram.port != _remotePort) {
        final from = '$host:${datagram.port}';
        if (!_maybeLatch(from, datagram.address, datagram.port)) {
          _rxDropped++;
          if (_rxDropped <= 3 || _rxDropped % 500 == 0) {
            sipLog('[RTP] Dropped packet #$_rxDropped from $from '
                '(focused on $_remoteHost:$_remotePort)');
          }
          return;
        }
      } else {
        _lastFromFocused = DateTime.now();
      }
    }

    final data = datagram.data;
    _rxCount++;
    if (_rxCount <= 3 || _rxCount % 500 == 0) {
      sipLog('[RTP] Received packet #$_rxCount, ${data.length} bytes from '
          '${datagram.address.address}:${datagram.port}');
    }
    if (data.length < 12 || (data[0] >> 6) != 2) return;

    final padding = (data[0] >> 5) & 0x01;
    final extension = (data[0] >> 4) & 0x01;
    final csrcCount = data[0] & 0x0F;
    final payloadType = data[1] & 0x7F;
    // RTCP multiplexed on the same port (PT 72-76 with marker) is not audio.
    if (payloadType >= 72 && payloadType <= 76) return;

    var headerLength = 12 + csrcCount * 4;
    if (extension == 1 && data.length >= headerLength + 4) {
      final extLength =
          ((data[headerLength + 2] << 8) | data[headerLength + 3]) * 4;
      headerLength += 4 + extLength;
    }
    var payloadLength = data.length - headerLength;
    if (padding == 1 && payloadLength > 0) {
      payloadLength -= data[data.length - 1];
    }
    if (payloadLength <= 0 || headerLength + payloadLength > data.length) {
      return;
    }
    final payload =
        Uint8List.sublistView(data, headerLength, headerLength + payloadLength);
    onRtpPayload?.call(payload, payloadType);
    if (payloadType == 0 || payloadType == 8) onAudioReceived?.call(payload);
  }

  /// Follow [from] instead of the announced endpoint once it is clearly the
  /// call's audio: the announced endpoint sent nothing for 400 ms, the
  /// source is not another call's endpoint, and it delivered at least 8
  /// packets in a row.
  bool _maybeLatch(String from, InternetAddress address, int port) {
    if (otherLegEndpoints.contains(from)) return false;
    final now = DateTime.now();
    if (now.difference(_lastFromFocused).inMilliseconds < 400) return false;
    if (_candidate != from ||
        now.difference(_candidateSince).inMilliseconds > 1500) {
      _candidate = from;
      _candidateCount = 0;
      _candidateSince = now;
    }
    _candidateCount++;
    if (_candidateCount < 8) return false;
    sipLog('[RTP] Latched onto $from, the announced '
        '$_remoteHost:$_remotePort sent nothing');
    _remoteHost = address.address;
    _remotePort = port;
    _remoteAddress = address;
    _lastFromFocused = now;
    _candidate = null;
    _candidateCount = 0;
    return true;
  }

  /// Send one RTP packet with [audioData]. The timestamp advances by the
  /// number of samples (one byte per sample for G.711).
  void sendAudio(Uint8List audioData, int payloadType) {
    if (_dtmfActive) return;
    _sendPacket(audioData, payloadType, _timestamp, marker: _marker);
    _marker = false;
    _timestamp = (_timestamp + audioData.length) & 0xFFFFFFFF;
  }

  /// Send 20 ms of silence in the current codec. Opens NAT pinholes and
  /// lets symmetric-RTP servers learn our address.
  void sendSilence() {
    final pt = sendPayloadType;
    final silence = Uint8List(160)..fillRange(0, 160, pt == 0 ? 0xFF : 0xD5);
    sendAudio(silence, pt);
  }

  /// Send [digit] as RFC 4733 telephone-event packets. Audio packets are
  /// paused while the event plays.
  Future<void> sendDtmf(String digit, {int durationMs = 160}) async {
    final pt = dtmfPayloadType;
    final event = _dtmfEvent(digit);
    if (pt == null || event == null || _rtpSocket == null) return;
    while (_dtmfActive) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _dtmfActive = true;
    try {
      final start = _timestamp;
      final steps = max(1, durationMs ~/ 20);
      const volume = 10;
      for (var i = 1; i <= steps; i++) {
        final duration = i * 160;
        _sendPacket(_dtmfPayload(event, false, volume, duration), pt, start,
            marker: i == 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final total = steps * 160;
      // The end packet is sent three times for robustness (RFC 4733 2.5.1.4).
      for (var i = 0; i < 3; i++) {
        _sendPacket(_dtmfPayload(event, true, volume, total), pt, start);
      }
      _timestamp = (start + total) & 0xFFFFFFFF;
      _marker = true;
    } finally {
      _dtmfActive = false;
    }
  }

  static int? _dtmfEvent(String digit) {
    const map = {
      '0': 0, '1': 1, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7,
      '8': 8, '9': 9, '*': 10, '#': 11, 'A': 12, 'B': 13, 'C': 14, 'D': 15,
    };
    return map[digit.toUpperCase()];
  }

  static Uint8List _dtmfPayload(int event, bool end, int volume, int duration) {
    return Uint8List.fromList([
      event,
      (end ? 0x80 : 0) | (volume & 0x3F),
      (duration >> 8) & 0xFF,
      duration & 0xFF,
    ]);
  }

  void _sendPacket(Uint8List payload, int payloadType, int timestamp,
      {bool marker = false}) {
    final sender = _sender;
    final address = _remoteAddress;
    final port = _remotePort;
    if (sender == null || address == null || port == null) return;
    try {
      final packet = Uint8List(12 + payload.length);
      packet[0] = 0x80;
      packet[1] = (marker ? 0x80 : 0) | (payloadType & 0x7F);
      packet[2] = (_sequenceNumber >> 8) & 0xFF;
      packet[3] = _sequenceNumber & 0xFF;
      _sequenceNumber = (_sequenceNumber + 1) & 0xFFFF;
      packet[4] = (timestamp >> 24) & 0xFF;
      packet[5] = (timestamp >> 16) & 0xFF;
      packet[6] = (timestamp >> 8) & 0xFF;
      packet[7] = timestamp & 0xFF;
      packet[8] = (_ssrc >> 24) & 0xFF;
      packet[9] = (_ssrc >> 16) & 0xFF;
      packet[10] = (_ssrc >> 8) & 0xFF;
      packet[11] = _ssrc & 0xFF;
      packet.setRange(12, packet.length, payload);
      sender.send(packet, address, port);
      _txCount++;
      if (_txCount <= 3 || _txCount % 500 == 0) {
        sipLog('[RTP] Sent packet #$_txCount to $_remoteHost:$_remotePort');
      }
    } catch (e) {
      if (_txCount % 100 == 0) sipLog('[RTP] Send error: $e');
    }
  }

  /// Close the socket and reset state.
  void close() {
    if (_rtpSocket != null) {
      sipLog('[RTP] Closing. Received: $_rxCount packets, sent: $_txCount');
    }
    _rtpSocket?.close();
    _rtpSocket = null;
    _sender = null;
    _localRtpPort = null;
    _remoteHost = null;
    _remotePort = null;
    _remoteAddress = null;
    _isActive = false;
    _dtmfActive = false;
    otherLegEndpoints = <String>{};
    _rxCount = 0;
    _txCount = 0;
    _rxDropped = 0;
  }
}
