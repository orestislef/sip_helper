/// SDP helpers: build our offer/answer, parse the remote description and
/// pick the codec (RFC 3264 offer/answer, G.711 only).
library;

/// RTP payload type of G.711 µ-law.
const int payloadPcmu = 0;

/// RTP payload type of G.711 A-law.
const int payloadPcma = 8;

/// Default payload type we offer for RFC 4733 telephone-event (DTMF).
const int defaultDtmfPayload = 101;

/// SDP media direction attribute.
enum MediaDirection {
  sendrecv,
  sendonly,
  recvonly,
  inactive;

  /// The direction to put in an answer to an offer with this direction,
  /// given whether we ourselves currently hold the call.
  MediaDirection answerFor({bool localHold = false}) {
    final remoteSends = this == sendrecv || this == sendonly;
    final remoteReceives = this == sendrecv || this == recvonly;
    // We always want to receive while the remote sends; we only send when
    // the remote receives and we are not holding.
    final weSend = remoteReceives && !localHold;
    final weReceive = remoteSends;
    if (weSend && weReceive) return sendrecv;
    if (weSend) return sendonly;
    if (weReceive) return recvonly;
    return inactive;
  }

  /// True when this direction, offered by the remote, means the remote has
  /// put the call on hold (it will not send to us any more, RFC 3264 8.4).
  bool get isHoldOffer => this == sendonly || this == inactive;
}

/// What we need from a remote SDP.
class SdpInfo {
  /// Connection address of the audio stream.
  final String? host;

  /// RTP port of the audio stream (0 means the stream was rejected).
  final int? port;

  /// Payload types listed on the `m=audio` line, in order.
  final List<int> payloads;

  /// Payload type mapped to `telephone-event/8000`, if any.
  final int? telephoneEvent;

  /// Media direction (media level overrides session level).
  final MediaDirection direction;

  /// True when an `m=audio` line was present.
  final bool hasAudio;

  const SdpInfo({
    this.host,
    this.port,
    this.payloads = const [],
    this.telephoneEvent,
    this.direction = MediaDirection.sendrecv,
    this.hasAudio = false,
  });

  /// `host:port` of the remote RTP endpoint, or null.
  String? get endpoint =>
      host != null && port != null && port! > 0 ? '$host:$port' : null;

  /// True when this SDP puts the call on hold, including the old RFC 2543
  /// `c=0.0.0.0` style.
  bool get isHold => direction.isHoldOffer || host == '0.0.0.0';

  /// Parse [sdp]. Only the first audio stream is considered.
  factory SdpInfo.parse(String sdp) {
    String? sessionHost;
    String? mediaHost;
    int? port;
    final payloads = <int>[];
    int? dtmf;
    MediaDirection? sessionDir;
    MediaDirection? mediaDir;
    var inAudio = false;
    var seenAudio = false;
    var pastAudio = false;

    for (final raw in sdp.split('\n')) {
      final line = raw.trim();
      if (line.length < 2 || line[1] != '=') continue;
      if (line.startsWith('m=')) {
        if (seenAudio) {
          pastAudio = true;
          inAudio = false;
          continue;
        }
        if (line.startsWith('m=audio ')) {
          inAudio = true;
          seenAudio = true;
          final parts = line.split(RegExp(r'\s+'));
          if (parts.length >= 2) port = int.tryParse(parts[1].split('/').first);
          for (final p in parts.skip(3)) {
            final v = int.tryParse(p);
            if (v != null) payloads.add(v);
          }
        } else {
          inAudio = false;
        }
        continue;
      }
      if (pastAudio) continue;
      final atSession = !seenAudio;
      if (line.startsWith('c=')) {
        final parts = line.substring(2).split(RegExp(r'\s+'));
        if (parts.length >= 3) {
          final addr = parts[2].split('/').first;
          if (atSession) {
            sessionHost = addr;
          } else if (inAudio) {
            mediaHost = addr;
          }
        }
        continue;
      }
      if (!line.startsWith('a=')) continue;
      final attr = line.substring(2);
      final dir = switch (attr) {
        'sendrecv' => MediaDirection.sendrecv,
        'sendonly' => MediaDirection.sendonly,
        'recvonly' => MediaDirection.recvonly,
        'inactive' => MediaDirection.inactive,
        _ => null,
      };
      if (dir != null) {
        if (atSession) {
          sessionDir = dir;
        } else if (inAudio) {
          mediaDir = dir;
        }
        continue;
      }
      if (inAudio &&
          attr.startsWith('rtpmap:') &&
          attr.toLowerCase().contains('telephone-event/8000')) {
        dtmf = int.tryParse(attr.substring(7).split(RegExp(r'\s+')).first);
      }
    }

    return SdpInfo(
      host: mediaHost ?? sessionHost,
      port: port,
      payloads: payloads,
      telephoneEvent: dtmf,
      direction: mediaDir ?? sessionDir ?? MediaDirection.sendrecv,
      hasAudio: seenAudio,
    );
  }

  /// The G.711 codec to use with this SDP, or null when it offers none.
  ///
  /// When answering an offer ([isAnswer] false) A-law wins when offered,
  /// otherwise µ-law. For an answer to our own offer the first G.711 codec
  /// in the remote list is what the answerer chose.
  int? chooseCodec({bool isAnswer = false}) {
    if (isAnswer) {
      for (final p in payloads) {
        if (p == payloadPcma || p == payloadPcmu) return p;
      }
      return null;
    }
    if (payloads.contains(payloadPcma)) return payloadPcma;
    if (payloads.contains(payloadPcmu)) return payloadPcmu;
    return null;
  }
}

/// Build an SDP body.
///
/// Without [codec] this is an offer listing A-law, µ-law and
/// telephone-event. With [codec] it is an answer that lists only the chosen
/// codec (and [dtmf] when the offer had telephone-event), since an answer
/// may not add codecs the offer did not contain.
String buildSdp({
  required String localIp,
  required int rtpPort,
  required int sessionId,
  required int sessionVersion,
  MediaDirection direction = MediaDirection.sendrecv,
  int? codec,
  int? dtmf,
  String sessionName = 'sip_helper',
}) {
  final List<String> media;
  if (codec == null) {
    media = [
      'm=audio $rtpPort RTP/AVP $payloadPcma $payloadPcmu $defaultDtmfPayload',
      'a=rtpmap:$payloadPcma PCMA/8000',
      'a=rtpmap:$payloadPcmu PCMU/8000',
      'a=rtpmap:$defaultDtmfPayload telephone-event/8000',
      'a=fmtp:$defaultDtmfPayload 0-15',
    ];
  } else {
    final name = codec == payloadPcmu ? 'PCMU' : 'PCMA';
    media = [
      'm=audio $rtpPort RTP/AVP $codec${dtmf != null ? ' $dtmf' : ''}',
      'a=rtpmap:$codec $name/8000',
      if (dtmf != null) 'a=rtpmap:$dtmf telephone-event/8000',
      if (dtmf != null) 'a=fmtp:$dtmf 0-15',
    ];
  }
  final lines = [
    'v=0',
    'o=- $sessionId $sessionVersion IN IP4 $localIp',
    's=$sessionName',
    'c=IN IP4 $localIp',
    't=0 0',
    ...media,
    'a=ptime:20',
    'a=${direction.name}',
  ];
  return '${lines.join('\r\n')}\r\n';
}
