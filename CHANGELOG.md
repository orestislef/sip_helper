## 0.4.2

- Dart 3.7 and Flutter 3.29 or newer. `ffi` 2.2.0 already needed Dart 3.7, so 3.4 to 3.6 could not resolve the package anyway. Nothing else changes for apps.
- `crypto` raised to ^3.0.8, the latest.
- The example app moved from `package:flutter/material.dart`, deprecated in Flutter 3.47, to [material_ui](https://pub.dev/packages/material_ui). It now needs Flutter 3.47. The package itself uses no Material.
- Code formatted with the Dart 3.7 style.

## 0.4.1

- New `allowContactRewrite` option (in `SipConfiguration` and `UdpSipClient`), off by default. Behind NAT the client takes the public address the server reports in the REGISTER response (Via `received` and `rport`), uses it in Contact, Via and SDP and registers again with it. Same as "Allow IP rewrite" in MicroSIP. Needed when the server does not rewrite contacts itself, otherwise incoming calls do not arrive.

## 0.4.0

The package is now a Flutter plugin with native call audio on Android and iOS, and the SIP layer was rebuilt from a call center app that runs on Asterisk all day.

**Breaking**

- Requires Flutter (the native audio needs a plugin). Dart 3.4 or newer.
- `UdpSipClient` takes a `SipMediaHandler` instead of the `onRtp*` / `onMicrophone*` / `onAudioCleanup` callbacks, `onIncomingCall` now also passes the caller name, and `onCallStateChanged` passes a `SipCallEvent` instead of a string.
- `AudioRecorder.open()` returns `FutureOr<bool>` (existing sync backends still compile). `AudioPlatform` has a new optional `session`.
- `SipHelper.disconnect()` now hangs up live calls and un-registers before closing the socket.
- Registration state is reported only when it changes, not on every refresh.

**New**

- Android backend: AudioRecord on the voice communication source with echo cancellation, noise suppression and AGC, AudioTrack playback, communication mode and audio focus, speaker, earpiece and Bluetooth routing, proximity screen off, foreground service during calls, runtime permission request.
- iOS backend: AVAudioEngine with voice processing, play and record session during calls, speaker override, Bluetooth, proximity, interruption and route change recovery, permission request.
- `SipHelper`: `callEventStream`, `calls`, `transferCall`, `sendDtmf`, `declineCall`, `setMuted`, `setSpeakerphone`, `requestMicrophonePermission`, `reconnect`, automatic ring and ringback tones, automatic hold of the other calls. `makeCall` returns the Call-ID, `holdCall` and `unholdCall` return whether the PBX accepted.
- Blind transfer with REFER and NOTIFY.
- DTMF as RFC 4733 telephone-event, SIP INFO fallback.
- G.711 µ-law (PCMU) encoder and decoder, codec picked from the other side's offer.
- Digest auth for every request (REGISTER, INVITE, re-INVITE, BYE, REFER), 407 Proxy-Authenticate, qop, opaque, SHA-256, stale nonces.
- Clean un-REGISTER (`Expires: 0`) on disconnect, registration refresh based on the granted expiry, 423 Min-Expires, retry with backoff.
- NAT keep-alives (`keepAliveInterval`), `authUsername`, `userAgent` in `SipConfiguration`. `registerInterval` is now used as the registration lifetime.
- Several calls at once: shared RTP socket and microphone are owned by the live call, held calls' audio is filtered out.
- Symmetric RTP latching when the PBX sends from a different address than its SDP.
- Early media on 183 Session Progress.
- Delayed offer (INVITE or re-INVITE without SDP), 488 for offers without G.711.

**Fixed**

- CSeq is tracked per dialog, and ACKs carry the CSeq of the INVITE they acknowledge.
- The ACK for a 4xx to INVITE reuses the INVITE branch.
- CANCEL waits for a provisional response, and a 200 OK that crosses a CANCEL is ACKed and hung up.
- Lost UDP packets: requests are retransmitted, our 200 OK is repeated until the ACK arrives, retransmitted INVITEs no longer ring twice.
- On Windows back-to-back UDP sends were silently dropped (100 Trying + 180 Ringing, ACK + BYE). Sends are now queued until the socket takes them.
- G.711 A-law encoder had the sign bit inverted compared with the standard and the decoder.
- Remote hold no longer stops the microphone of another call, a session refresh no longer fires hold events again, and our own hold is kept when the PBX re-offers.
- Retransmitted hold 200 OK no longer restarts the microphone.
- RTP timestamps advance by the real number of samples, payload type 0 is played as µ-law, DTMF and comfort noise packets are not played as audio.
- Requests the client does not support get 501 instead of no answer, all Via headers are echoed, header names are case-insensitive and compact forms are understood.
- Upsampling to 16 kHz uses linear interpolation instead of sample doubling.

## 0.3.0

- **Breaking:** cross-platform audio abstraction. `WinAudioPlayer`, `WinAudioRecorder`, `WinAudioDevices` are no longer exported from the barrel file. Use `AudioPlatform.instance.createPlayer()`, `AudioPlatform.instance.createRecorder()`, and `AudioPlatform.instance.devices` instead.
- New abstract interfaces: `AudioPlayer`, `AudioRecorder`, `AudioDevices` for platform-agnostic audio.
- `AudioPlatform` singleton auto-detects the platform at runtime (Windows → WinMM, others → stub).
- Custom audio backends can be registered via `AudioPlatform.override()`.
- Removed `platforms: windows:` restriction, SIP/RTP/codec now works on all Dart platforms.
- Stub backend allows graceful degradation on unsupported platforms (audio returns `false` from `open()`).

## 0.2.3

- Fix: local IP detection. TCP connect to server is now the primary method (OS picks correct route). Falls back to subnet matching, then interface name heuristic. Fixes wrong IP on machines with Hyper-V/WSL virtual adapters.

## 0.2.2

- Fix: local IP detection now picks the interface that can route to the SIP server instead of grabbing the first `192.168.*` address. Uses UDP probe with TCP and NetworkInterface fallbacks.

## 0.2.1

- Fix: add `rport` to all SIP Via headers for NAT traversal, fixes incoming calls failing with "unavailable".
- Fix: send 100 Trying immediately on incoming INVITE before 180 Ringing to prevent server timeout.

## 0.2.0

- Feature: call hold and resume via SIP re-INVITE (`holdCall`, `unholdCall`).
- Feature: remote hold detection (HELD/RESUMED/REMOTE_HELD/REMOTE_RESUMED states).
- Feature: `activeCalls` getter to query all current calls.
- Feature: proper incoming re-INVITE handling with SDP direction negotiation.
- Fix: hanging up an outgoing call while ringing now sends SIP CANCEL instead of BYE.
- Fix: late 200 OK received after CANCEL is properly ACKed and followed by BYE.
- Fix: 487/486/603 final responses are now ACKed correctly.
- Fix: ACK direction-aware for incoming call dialogs.

## 0.1.2

- Updated dependencies: ffi ^2.2.0, crypto ^3.0.7, lints ^6.1.0, test ^1.30.0.

## 0.1.1

- Fix: AudioPlayerService was not initialized by SipHelper, causing no voice playback during calls.

## 0.1.0

- Initial release.
- SIP protocol support over UDP (REGISTER, INVITE, BYE, ACK, CANCEL).
- RTP audio transport with sequence numbering and timestamping.
- G.711 A-law (PCMA) encoder and decoder.
- Windows audio capture and playback via WinMM FFI.
- Audio level metering (RMS-based, normalized 0.0-1.0).
- Pure Dart SIP configuration and call info models.
- Pluggable logging abstraction.
