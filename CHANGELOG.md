## 0.2.2

- Fix: local IP detection now picks the interface that can route to the SIP server instead of grabbing the first `192.168.*` address. Uses UDP probe with TCP and NetworkInterface fallbacks.

## 0.2.1

- Fix: add `rport` to all SIP Via headers for NAT traversal — fixes incoming calls failing with "unavailable".
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
