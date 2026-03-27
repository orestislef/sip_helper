# sip_helper

A lightweight SIP/VoIP library for Dart. Implements the SIP protocol over UDP with G.711 A-law (PCMA) codec and RTP audio transport for real-time voice calls.

## Features

- **SIP Protocol** - Full SIP/UDP implementation (REGISTER, INVITE, BYE, CANCEL, OPTIONS, ACK)
- **SIP Digest Auth** - MD5 challenge-response authentication (RFC 2617)
- **RTP Audio** - RTP/AVP transport for real-time audio streaming
- **G.711 A-law Codec** - PCMA encoder/decoder (ITU-T G.711)
- **Cross-Platform Audio** - Pluggable audio backend (WinMM on Windows, extensible to other platforms)
- **Bluetooth Support** - Automatic A2DP to HFP profile switching for call audio
- **Audio Device Selection** - Enumerate and select input/output devices
- **Gain Controls** - Adjustable input/output gain
- **Ring Tones** - 5 built-in synthesized ring tones
- **Ringback Tone** - Standard 425Hz ringback for outgoing calls
- **DTMF** - In-call DTMF tone generation
- **Audio Levels** - Real-time input/output level computation for UI visualization

## Platform Support

| Platform | Audio Status |
|----------|-------------|
| Windows  | Supported (WinMM FFI) |
| macOS    | SIP/RTP works, audio backend not yet implemented |
| Linux    | SIP/RTP works, audio backend not yet implemented |
| Android  | SIP/RTP works, audio backend not yet implemented |
| iOS      | SIP/RTP works, audio backend not yet implemented |

> SIP signaling, RTP transport, and codecs are pure Dart and work on all platforms. Audio capture/playback requires a platform-specific backend. Windows uses WinMM via `dart:ffi`. Other platforms can register custom backends via `AudioPlatform.override()`.

## Getting Started

### Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  sip_helper: ^0.1.0
```

### Basic Usage

```dart
import 'package:sip_helper/sip_helper.dart';

void main() async {
  // Optional: receive log output
  sipLogger = print;

  // Configure SIP account
  final config = SipConfiguration(
    server: 'pbx.example.com',
    username: '1001',
    password: 'secret',
    displayName: 'John Doe',
  );

  // Initialize and connect
  final sip = SipHelper.instance;
  await sip.initialize(config);
  await sip.connect();

  // Listen for events
  sip.connectionStateStream.listen((connected) {
    print('Registered: $connected');
  });

  sip.incomingCallStream.listen((call) {
    print('Incoming call from ${call.callerNumber}');
    sip.answerCall(call.callId!);
  });

  // Make a call
  await sip.makeCall('1002');
}
```

## Architecture

```
lib/
  sip_helper.dart                       # Barrel export
  src/
    sip_helper_service.dart             # Orchestrator (SipHelper)
    logging.dart                        # Pluggable logger
    models/
      sip_configuration.dart            # SIP account config
      call_info.dart                    # Call state model
    sip/
      udp_sip_client.dart              # SIP protocol implementation
      sip_call.dart                    # Active call tracking
    rtp/
      rtp_session.dart                 # RTP packet send/receive
    codec/
      pcma_encoder.dart                # G.711 A-law encoder
      pcma_decoder.dart                # G.711 A-law decoder
    audio/
      sound_service.dart               # Tone generation + voice playback
      audio_player_service.dart        # PCMA decode + upsample pipeline
      microphone_service.dart          # Microphone capture
      audio_level.dart                 # Real-time level computation
    platform/
      audio_platform.dart             # Abstract audio interfaces
      audio_platform_registry.dart    # Platform auto-detection
      windows/
        win32_audio.dart              # WinMM FFI bindings
        win32_audio_backend.dart      # WinMM adapter
      stub/
        stub_audio_backend.dart       # No-op fallback
```

### Audio Pipeline

**Outgoing (Mic → Network):**
```
Platform Audio In (8kHz PCM16) → Input Gain → PCMA Encode → RTP Send
```

**Incoming (Network → Speaker):**
```
RTP Receive → PCMA Decode (8kHz PCM16) → Upsample 2x (16kHz) → Output Gain → Platform Audio Out
```

## API Reference

### SipHelper (Orchestrator)

The main entry point. Wires together SIP signaling, RTP audio, and platform audio services.

```dart
final sip = SipHelper.instance;

// Lifecycle
await sip.initialize(config);  // Wire up all services
await sip.connect();           // Register with SIP server
await sip.disconnect();        // Unregister

// Call management
await sip.makeCall('1002');        // Outgoing call
await sip.answerCall(callId);      // Answer incoming
await sip.hangupCall(callId);      // Hang up

// Event streams
sip.connectionStateStream  // Stream<bool>
sip.incomingCallStream      // Stream<CallInfo>
sip.callStateStream         // Stream<String> (callId:state)
sip.errorStream             // Stream<String>

// Sub-services
sip.soundService            // Ring tones, voice playback, gain
sip.microphoneService       // Mic capture, input gain
sip.audioLevelService       // Real-time audio levels
sip.rtpSession              // RTP transport
```

### SipConfiguration

```dart
SipConfiguration(
  server: 'pbx.example.com',
  username: '1001',
  password: 'secret',
  displayName: 'John Doe',  // Optional
  port: 5060,               // Default: 5060
  transport: 'UDP',         // Default: UDP
  autoRegister: true,       // Default: true
  registerInterval: 600,    // Seconds, default: 600
)
```

### Audio Device Selection

```dart
// List available devices
final platform = AudioPlatform.instance;
final outputs = platform.devices.getOutputDevices();
final inputs = platform.devices.getInputDevices();

// Select devices by index
sip.soundService.setOutputDevice(0);
sip.microphoneService.setInputDevice(0);

// Adjust gain
sip.soundService.setOutputGain(5.0);      // 500%
sip.microphoneService.setInputGain(1.0);  // 100%
```

### Ring Tones

```dart
sip.soundService.setRingTone(RingTone.chime);    // Default
sip.soundService.setRingTone(RingTone.classic);
sip.soundService.setRingTone(RingTone.soft);
sip.soundService.setRingTone(RingTone.alert);
sip.soundService.setRingTone(RingTone.melody);

// Preview
sip.soundService.previewRingTone(RingTone.melody);
```

### Logging

```dart
// Route all sip_helper logs to your logger
sipLogger = (message) => myLogger.info(message);

// Or simply use print
sipLogger = print;
```

## Requirements

- **Dart SDK** >= 3.0.0
- **Windows 10/11** for built-in audio (WinMM). Other platforms: SIP/RTP works, bring your own audio backend.
- **SIP Server** — Asterisk, FreeSWITCH, or any RFC 3261 compliant server

## License

MIT License - see [LICENSE](LICENSE) for details.
