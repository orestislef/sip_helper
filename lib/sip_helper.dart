/// A lightweight SIP/VoIP library for Dart.
///
/// Provides SIP protocol signaling (UDP), RTP audio transport,
/// G.711 A-law (PCMA) codec, and Windows native audio via WinMM FFI.
///
/// ```dart
/// import 'package:sip_helper/sip_helper.dart';
///
/// final sip = SipHelper.instance;
/// await sip.initialize(SipConfiguration(
///   server: 'pbx.example.com',
///   username: '1001',
///   password: 'secret',
/// ));
/// await sip.connect();
/// ```
library;

// Logging
export 'src/logging.dart';

// Models
export 'src/models/sip_configuration.dart';
export 'src/models/call_info.dart';

// Codec
export 'src/codec/pcma_encoder.dart';
export 'src/codec/pcma_decoder.dart';

// SIP
export 'src/sip/udp_sip_client.dart';
export 'src/sip/sip_call.dart';

// RTP
export 'src/rtp/rtp_session.dart';

// Audio
export 'src/audio/audio_level.dart';
export 'src/audio/audio_player_service.dart';
export 'src/audio/microphone_service.dart';
export 'src/audio/sound_service.dart';

// Platform - Windows
export 'src/platform/windows/win32_audio.dart';

// Orchestrator
export 'src/sip_helper_service.dart';
