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
