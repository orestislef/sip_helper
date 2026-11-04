# sip_helper

SIP calls for Flutter. Add the package, point it at your PBX and you can register, place and answer calls, hold, resume, transfer, send DTMF and talk, on Android, iOS and Windows. No WebRTC, no native SIP library: the SIP stack, RTP and the G.711 codecs are plain Dart, and each platform only provides the microphone and speaker.

The call handling comes from a call center app that runs on Asterisk all day.

## What it does

- SIP over UDP: REGISTER with digest auth (MD5, SHA-256, qop, 401 and 407), automatic refresh, clean un-REGISTER, NAT keep-alives
- incoming and outgoing calls, ringing, early media (183), CANCEL, busy and failure reasons
- hold and resume with re-INVITE, remote hold detection, glare handling (491)
- blind transfer with REFER, result through NOTIFY
- DTMF as RFC 4733 telephone-event, or SIP INFO when the other side does not support it
- several calls at once: the other calls are put on hold automatically and their audio is kept apart
- G.711 A-law and µ-law, chosen from the other side's offer
- retransmissions for lost UDP packets in both directions
- native call audio: echo cancellation, speaker and earpiece, Bluetooth headsets, proximity screen off, mute
- built-in ring tone and ringback tone

## Platform support

| Platform | Audio |
|----------|-------|
| Android  | AudioRecord (voice communication source with echo cancellation) and AudioTrack, minSdk 21 |
| iOS      | AVAudioEngine with voice processing, iOS 13 or newer |
| Windows  | WinMM through `dart:ffi` |
| macOS, Linux | SIP and RTP work, no audio backend yet (bring your own with `AudioPlatform.override`) |

## Install

```yaml
dependencies:
  sip_helper: ^0.4.1
```

### Android

Nothing to do. The plugin adds the permissions it needs (`RECORD_AUDIO`, `INTERNET`, `MODIFY_AUDIO_SETTINGS`, `WAKE_LOCK`, `FOREGROUND_SERVICE_MICROPHONE`) and a small foreground service that keeps the microphone working while a call is up and the app is in the background. The microphone permission is asked for on the first call, or earlier with `requestMicrophonePermission()`.

If you publish on Google Play, declare the microphone foreground service type in the Play Console.

### iOS

Add to `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>The microphone is used for voice calls.</string>
<key>NSLocalNetworkUsageDescription</key>
<string>The local network is used to reach your phone system.</string>
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

The local network entry is only needed when the PBX is on your LAN. `audio` in background modes keeps a call going when the screen locks.

### Windows

Nothing to do.

## Usage

```dart
import 'package:sip_helper/sip_helper.dart';

final sip = SipHelper.instance;

await sip.initialize(const SipConfiguration(
  server: 'pbx.example.com',
  username: '1001',
  password: 'secret',
  displayName: 'Front desk',
));

sip.connectionStateStream.listen((registered) => print('registered: $registered'));
sip.errorStream.listen((error) => print(error));

sip.incomingCallStream.listen((call) {
  print('incoming call from ${call.displayName}');
  // sip.answerCall(call.callId!);  or  sip.declineCall(call.callId!);
});

sip.callEventStream.listen((e) {
  print('${e.callId}: ${e.event.name}');   // ringing, confirmed, held, ended, ...
});

await sip.connect();

final callId = await sip.makeCall('1002');   // extension, number or sip: URI
```

During a call:

```dart
await sip.holdCall(callId);          // true once the PBX accepted it
await sip.unholdCall(callId);
sip.setMuted(true);
await sip.setSpeakerphone(true);     // Android and iOS
await sip.sendDtmf(callId, '1234#');
await sip.transferCall(callId, '1005');
await sip.hangupCall(callId);
```

`sip.calls` holds every known call as a `CallInfo` (number, name, direction, state, remote hold, duration). It is updated before each event is emitted, so a UI can just rebuild on `callEventStream`.

When you are done, `disconnect()` hangs up, un-registers and closes the socket. After a network change (Wi-Fi to mobile data) call `reconnect()`.

### Call events

| Event | Meaning |
|-------|---------|
| `calling` | our INVITE went out |
| `ringing` | the other side is ringing (or sent early media) |
| `confirmed` | the call is up |
| `held` / `resumed` | our hold or resume was accepted |
| `remoteHeld` / `remoteResumed` | the other side put us on hold or took us off |
| `transferred` | the PBX took over a transfer we started |
| `ended` | normal hangup, by either side |
| `cancelled` | the caller hung up before we answered |
| `declined` | busy or rejected |
| `failed` | not found, unavailable, auth failure, no answer from the server, no common codec |

`callStateStream` still gives the old `callId:STATE` strings.

### Options

```dart
SipConfiguration(
  server: 'pbx.example.com',
  port: 5060,
  username: '1001',
  password: 'secret',
  authUsername: '',          // when the auth user differs from the extension
  displayName: '',
  registerInterval: 600,     // registration lifetime in seconds
  keepAliveInterval: 25,     // NAT keep-alive in seconds, 0 to turn off
  allowContactRewrite: false, // use the public address the server reports
  userAgent: 'IQ-SIP',
)
```

```dart
sip.autoTones = true;           // ring tone and ringback played by the package
sip.autoHoldOtherCalls = true;  // hold the live call before answering or dialing another
sip.soundService.setRingTone(RingTone.classic);
```

### Lower level

`UdpSipClient` is the SIP user agent on its own. Give it a `SipMediaHandler` to plug in your own audio, or use it without audio for signalling only. `RtpSession`, `MicrophoneService`, `AudioPlayerService` and the codecs are exported too.

## Server notes

The client sends `rport`, keeps the NAT binding open and follows the RTP source when it differs from the SDP (symmetric RTP), so it works behind home routers and mobile networks. On the server side, for Asterisk:

- chan_sip: `nat=force_rport,comedia`, `directmedia=no`
- PJSIP: `rtp_symmetric=yes`, `force_rport=yes`, `rewrite_contact=yes`, `direct_media=no`

Allow `ulaw` and/or `alaw` on the endpoint.

When the server cannot be set up that way, turn on `allowContactRewrite`. The client then takes the public address the server reports in the REGISTER response (`received` and `rport`), puts it in Contact, Via and SDP and registers again with it, like "Allow IP rewrite" in MicroSIP.

## Limits

- UDP only (no TCP or TLS), no SRTP
- G.711 only
- incoming calls arrive while the app is running. Waking a closed app for a call needs push (CallKit on iOS, a high priority push and a full screen notification on Android), which is not part of this package

## Logging

```dart
sipLogger = print;            // or your logger
sipLogFullMessages = true;    // full SIP messages, credentials masked
```

## License

MIT, see [LICENSE](LICENSE).
