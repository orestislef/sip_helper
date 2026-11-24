import 'package:flutter_test/flutter_test.dart';
import 'package:sip_helper/src/sip/sdp.dart';

String _sdp(List<String> lines) => '${lines.join('\r\n')}\r\n';

void main() {
  group('SdpInfo.parse', () {
    test('reads endpoint, payloads, telephone-event and direction', () {
      final info = SdpInfo.parse(
        _sdp([
          'v=0',
          'o=- 1 1 IN IP4 10.0.0.1',
          's=-',
          'c=IN IP4 10.0.0.1',
          't=0 0',
          'm=audio 12000 RTP/AVP 0 8 101',
          'a=rtpmap:0 PCMU/8000',
          'a=rtpmap:8 PCMA/8000',
          'a=rtpmap:101 telephone-event/8000',
          'a=sendonly',
        ]),
      );
      expect(info.hasAudio, isTrue);
      expect(info.host, '10.0.0.1');
      expect(info.port, 12000);
      expect(info.endpoint, '10.0.0.1:12000');
      expect(info.payloads, [0, 8, 101]);
      expect(info.telephoneEvent, 101);
      expect(info.direction, MediaDirection.sendonly);
      expect(info.isHold, isTrue);
    });

    test('media level connection and direction override session level', () {
      final info = SdpInfo.parse(
        _sdp([
          'v=0',
          'c=IN IP4 1.1.1.1',
          'a=sendonly',
          'm=audio 5000 RTP/AVP 8',
          'c=IN IP4 2.2.2.2',
          'a=sendrecv',
          'm=video 6000 RTP/AVP 96',
          'c=IN IP4 3.3.3.3',
          'a=inactive',
        ]),
      );
      expect(info.host, '2.2.2.2');
      expect(info.direction, MediaDirection.sendrecv);
      expect(info.isHold, isFalse);
    });

    test('old style c=0.0.0.0 hold is detected', () {
      final info = SdpInfo.parse(
        _sdp(['v=0', 'c=IN IP4 0.0.0.0', 'm=audio 5000 RTP/AVP 8']),
      );
      expect(info.isHold, isTrue);
    });

    test('codec choice', () {
      SdpInfo offer(String payloads) =>
          SdpInfo.parse(_sdp(['v=0', 'm=audio 1 RTP/AVP $payloads']));
      expect(offer('0 8').chooseCodec(), payloadPcma);
      expect(offer('0 18').chooseCodec(), payloadPcmu);
      expect(offer('18 9').chooseCodec(), isNull);
      expect(offer('0 8').chooseCodec(isAnswer: true), payloadPcmu);
      expect(offer('101 8').chooseCodec(isAnswer: true), payloadPcma);
    });
  });

  group('MediaDirection.answerFor', () {
    test('mirrors the offer when not holding', () {
      expect(MediaDirection.sendrecv.answerFor(), MediaDirection.sendrecv);
      expect(MediaDirection.sendonly.answerFor(), MediaDirection.recvonly);
      expect(MediaDirection.recvonly.answerFor(), MediaDirection.sendonly);
      expect(MediaDirection.inactive.answerFor(), MediaDirection.inactive);
    });

    test('keeps our own hold in the answer', () {
      expect(
        MediaDirection.sendrecv.answerFor(localHold: true),
        MediaDirection.recvonly,
      );
      expect(
        MediaDirection.sendonly.answerFor(localHold: true),
        MediaDirection.recvonly,
      );
      expect(
        MediaDirection.recvonly.answerFor(localHold: true),
        MediaDirection.inactive,
      );
    });
  });

  group('buildSdp', () {
    test('offer lists A-law, u-law and telephone-event', () {
      final sdp = buildSdp(
        localIp: '10.0.0.2',
        rtpPort: 4000,
        sessionId: 7,
        sessionVersion: 1,
      );
      expect(sdp, contains('m=audio 4000 RTP/AVP 8 0 101\r\n'));
      expect(sdp, contains('a=rtpmap:8 PCMA/8000'));
      expect(sdp, contains('a=rtpmap:0 PCMU/8000'));
      expect(sdp, contains('a=rtpmap:101 telephone-event/8000'));
      expect(sdp, contains('o=- 7 1 IN IP4 10.0.0.2'));
      expect(sdp, contains('c=IN IP4 10.0.0.2'));
      expect(sdp, contains('a=sendrecv'));
      expect(sdp.endsWith('\r\n'), isTrue);
    });

    test('answer lists only the chosen codec and the offered DTMF type', () {
      final sdp = buildSdp(
        localIp: '10.0.0.2',
        rtpPort: 4000,
        sessionId: 7,
        sessionVersion: 2,
        codec: payloadPcmu,
        dtmf: 96,
        direction: MediaDirection.recvonly,
      );
      expect(sdp, contains('m=audio 4000 RTP/AVP 0 96\r\n'));
      expect(sdp, isNot(contains('PCMA')));
      expect(sdp, contains('a=rtpmap:96 telephone-event/8000'));
      expect(sdp, contains('a=recvonly'));
    });

    test('a parsed offer of our own SDP round-trips', () {
      final info = SdpInfo.parse(
        buildSdp(
          localIp: '192.168.1.5',
          rtpPort: 30000,
          sessionId: 1,
          sessionVersion: 1,
          direction: MediaDirection.sendonly,
        ),
      );
      expect(info.endpoint, '192.168.1.5:30000');
      expect(info.payloads, [8, 0, 101]);
      expect(info.telephoneEvent, 101);
      expect(info.direction, MediaDirection.sendonly);
    });
  });
}
