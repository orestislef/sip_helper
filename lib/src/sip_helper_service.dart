import 'dart:async';
import 'dart:typed_data';
import 'logging.dart';
import 'models/sip_configuration.dart';
import 'models/call_info.dart';
import 'sip/udp_sip_client.dart';
import 'rtp/rtp_session.dart';
import 'audio/audio_player_service.dart';
import 'audio/microphone_service.dart';
import 'audio/sound_service.dart';
import 'audio/audio_level.dart';

/// Orchestrator service that wires together SIP signaling, RTP audio,
/// microphone capture, audio playback, and sound effects into a single API.
class SipHelper {
  static final SipHelper instance = SipHelper._internal();
  SipHelper._internal();

  UdpSipClient? _client;
  SipConfiguration? _config;

  // Stream controllers for events
  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();
  final StreamController<CallInfo> _incomingCallController =
      StreamController<CallInfo>.broadcast();
  final StreamController<String> _callStateController =
      StreamController<String>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  // Getters for streams
  Stream<bool> get connectionStateStream => _connectionStateController.stream;
  Stream<CallInfo> get incomingCallStream => _incomingCallController.stream;
  Stream<String> get callStateStream => _callStateController.stream;
  Stream<String> get errorStream => _errorController.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;
  SipConfiguration? get config => _config;

  // Expose sub-services for consumers who need direct access
  SoundService get soundService => SoundService.instance;
  MicrophoneService get microphoneService => MicrophoneService.instance;
  AudioLevelService get audioLevelService => AudioLevelService.instance;
  AudioPlayerService get audioPlayerService => AudioPlayerService.instance;
  RtpSession get rtpSession => RtpSession.instance;

  /// Initialize SIP helper with configuration and wire up all callbacks.
  Future<void> initialize(SipConfiguration config) async {
    try {
      _config = config;

      _client = UdpSipClient(
        server: config.server,
        port: config.port,
        username: config.username,
        password: config.password,
        displayName: config.displayName,
      );

      // ── Wire SIP client callbacks ──

      _client!.onRegistrationStateChanged = (registered) {
        _isConnected = registered;
        _connectionStateController.add(registered);
      };

      _client!.onIncomingCall = (from, callId) {
        final callInfo = CallInfo(
          callerNumber: from,
          callerName: null,
          callId: callId,
          sessionId: callId.hashCode,
          state: CallState.ringing,
          direction: CallDirection.incoming,
        );
        _incomingCallController.add(callInfo);
      };

      _client!.onCallStateChanged = (callId, state) {
        _callStateController.add('$callId:$state');
      };

      _client!.onError = (error) {
        _errorController.add(error);
      };

      // ── Wire audio callbacks (UdpSipClient → RtpSession / MicrophoneService) ──

      _client!.onRtpInitialize = () async {
        await RtpSession.instance.initialize();
        return RtpSession.instance.localPort;
      };

      _client!.onRtpSetRemoteEndpoint = (String host, int port) {
        RtpSession.instance.setRemoteEndpoint(host, port);
      };

      _client!.onRtpSendAudio = (Uint8List data, int payloadType) {
        RtpSession.instance.sendAudio(data, payloadType);
      };

      _client!.onRtpIsActive = () {
        return RtpSession.instance.isActive;
      };

      _client!.onRtpGetLocalPort = () {
        return RtpSession.instance.localPort;
      };

      _client!.onMicrophoneStart = () async {
        await MicrophoneService.instance.startCapture();
      };

      _client!.onAudioCleanup = () {
        try {
          MicrophoneService.instance.stopCapture();
        } catch (_) {}
        try {
          RtpSession.instance.close();
        } catch (_) {}
      };

      // ── Wire RtpSession.onAudioReceived → AudioPlayerService + AudioLevelService ──

      RtpSession.instance.onAudioReceived = (Uint8List audioPayload) {
        AudioPlayerService.instance.processAudioPacket(audioPayload);
        AudioLevelService.instance.updateOutputFromPcma(audioPayload);
      };

      // ── Wire MicrophoneService callbacks → RtpSession + AudioLevelService ──

      MicrophoneService.instance.onAudioCaptured = (Uint8List pcmaData, int payloadType) {
        RtpSession.instance.sendAudio(pcmaData, payloadType);
      };

      MicrophoneService.instance.onRawAudioCaptured = (Uint8List pcm16Data) {
        AudioLevelService.instance.updateInputFromPcm16(pcm16Data);
      };

      // ── Initialize sound service (ring tones, voice playback) ──

      SoundService.instance.initialize();

      sipLog('[SipHelper] Initialized with server ${config.server}:${config.port}');
    } catch (e) {
      _errorController.add('Failed to initialize SIP: ${e.toString()}');
      rethrow;
    }
  }

  /// Connect to SIP server
  Future<void> connect() async {
    if (_client == null) {
      throw Exception('SIP not initialized. Call initialize() first.');
    }

    try {
      await _client!.connect();
    } catch (e) {
      _errorController.add('Failed to connect: ${e.toString()}');
      rethrow;
    }
  }

  /// Disconnect from SIP server
  Future<void> disconnect() async {
    if (_client == null) return;

    try {
      await _client!.disconnect();
      _isConnected = false;
      _connectionStateController.add(false);
    } catch (_) {
      // Disconnect errors are intentionally ignored
    }
  }

  /// Answer incoming call
  Future<void> answerCall(String callId) async {
    if (_client == null) return;

    try {
      await _client!.answerCall(callId);
    } catch (e) {
      _errorController.add('Failed to answer call: ${e.toString()}');
    }
  }

  /// Decline/Hangup call
  Future<void> hangupCall(String callId) async {
    if (_client == null) return;

    try {
      await _client!.hangupCall(callId);
    } catch (e) {
      _errorController.add('Failed to hangup call: ${e.toString()}');
    }
  }

  /// Make outgoing call
  Future<void> makeCall(String destination) async {
    if (_client == null) {
      throw Exception('SIP not initialized');
    }

    if (!isConnected) {
      throw Exception('Not registered to SIP server');
    }

    try {
      await _client!.makeCall(destination);
    } catch (e) {
      _errorController.add('Failed to make call: ${e.toString()}');
      rethrow;
    }
  }

  /// Cleanup
  void dispose() {
    _client?.disconnect();
    _connectionStateController.close();
    _incomingCallController.close();
    _callStateController.close();
    _errorController.close();
  }
}
