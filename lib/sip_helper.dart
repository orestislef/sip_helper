/// SIP/VoIP for Flutter: SIP over UDP, RTP, G.711 A-law and µ-law, hold and
/// resume, blind transfer and DTMF, with native call audio on Android, iOS
/// and Windows.
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
export 'src/codec/pcmu_encoder.dart';
export 'src/codec/pcmu_decoder.dart';

// SIP
export 'src/sip/udp_sip_client.dart';
export 'src/sip/sip_call.dart';
export 'src/sip/sip_call_event.dart';
export 'src/sip/sip_media.dart';

// RTP
export 'src/rtp/rtp_session.dart';

// Audio
export 'src/audio/audio_level.dart';
export 'src/audio/audio_player_service.dart';
export 'src/audio/microphone_service.dart';
export 'src/audio/sound_service.dart';

// Platform audio abstraction
export 'src/platform/audio_platform.dart';
export 'src/platform/audio_platform_registry.dart';
export 'src/platform/windows/sip_helper_windows.dart';

// Orchestrator
export 'src/sip_helper_service.dart';
