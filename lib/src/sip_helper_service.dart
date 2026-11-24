import 'dart:async';
import 'dart:typed_data';

import 'audio/audio_level.dart';
import 'audio/audio_player_service.dart';
import 'audio/microphone_service.dart';
import 'audio/sound_service.dart';
import 'logging.dart';
import 'models/call_info.dart';
import 'models/sip_configuration.dart';
import 'platform/audio_platform_registry.dart';
import 'rtp/rtp_session.dart';
import 'sip/sip_call.dart';
import 'sip/sip_call_event.dart';
import 'sip/sip_media.dart';
import 'sip/udp_sip_client.dart';

/// A call event with the call it belongs to.
class SipCallEventInfo {
  final String callId;
  final SipCallEvent event;

  /// The tracked call, already updated for this event. Null only for calls
  /// the helper never saw (should not happen in practice).
  final CallInfo? call;

  const SipCallEventInfo(this.callId, this.event, this.call);

  @override
  String toString() => 'SipCallEventInfo($callId, ${event.name})';
}

/// Single entry point: SIP signalling, RTP, microphone, playback, tones and
/// the platform audio session, wired together.
///
/// ```dart
/// final sip = SipHelper.instance;
/// await sip.initialize(SipConfiguration(
///   server: 'pbx.example.com', username: '1001', password: 'secret'));
/// await sip.connect();
/// final callId = await sip.makeCall('1002');
/// ```
class SipHelper {
  static final SipHelper instance = SipHelper._internal();
  SipHelper._internal();

  UdpSipClient? _client;
  SipConfiguration? _config;
  final _DefaultMedia _media = _DefaultMedia();
  bool _audioWired = false;
  bool _sessionActive = false;

  final Map<String, CallInfo> _calls = {};

  /// Play the ring tone for incoming calls and the ringback tone for
  /// outgoing calls automatically.
  bool autoTones = true;

  /// Put the other live calls on hold before answering, dialing or resuming
  /// a call, like a desk phone does.
  bool autoHoldOtherCalls = true;

  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();
  final StreamController<CallInfo> _incomingCallController =
      StreamController<CallInfo>.broadcast();
  final StreamController<String> _callStateController =
      StreamController<String>.broadcast();
  final StreamController<SipCallEventInfo> _callEventController =
      StreamController<SipCallEventInfo>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  /// Registration state.
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  /// New incoming calls (state ringing).
  Stream<CallInfo> get incomingCallStream => _incomingCallController.stream;

  /// Call state as `callId:STATE` strings (CALLING, RINGING, CONFIRMED,
  /// HELD, RESUMED, REMOTE_HELD, REMOTE_RESUMED, TRANSFERRED, ENDED,
  /// CANCELED, DECLINED, FAILED). Prefer [callEventStream].
  Stream<String> get callStateStream => _callStateController.stream;

  /// Typed call events.
  Stream<SipCallEventInfo> get callEventStream => _callEventController.stream;

  /// Errors worth showing to the user.
  Stream<String> get errorStream => _errorController.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;
  SipConfiguration? get config => _config;

  /// The underlying SIP client (null before [initialize]).
  UdpSipClient? get client => _client;

  /// Calls currently known (ringing, active or held), by Call-ID.
  Map<String, CallInfo> get calls => Map.unmodifiable(_calls);

  /// SIP dialog state of active calls, by Call-ID.
  Map<String, SipCall> get activeCalls => _client?.activeCalls ?? {};

  SoundService get soundService => SoundService.instance;
  MicrophoneService get microphoneService => MicrophoneService.instance;
  AudioLevelService get audioLevelService => AudioLevelService.instance;
  AudioPlayerService get audioPlayerService => AudioPlayerService.instance;
  RtpSession get rtpSession => RtpSession.instance;
  AudioSession get audioSession => AudioPlatform.instance.session;

  /// Set up the account. Calling it again with a new configuration
  /// un-registers the previous account first.
  Future<void> initialize(
    SipConfiguration config, {
    bool? autoTones,
    bool? autoHoldOtherCalls,
  }) async {
    try {
      if (autoTones != null) this.autoTones = autoTones;
      if (autoHoldOtherCalls != null) {
        this.autoHoldOtherCalls = autoHoldOtherCalls;
      }
      final old = _client;
      if (old != null) {
        old.onRegistrationStateChanged = null;
        old.onIncomingCall = null;
        old.onCallStateChanged = null;
        old.onError = null;
        await old.unregister();
        _calls.clear();
        if (_isConnected) {
          _isConnected = false;
          _add(_connectionStateController, false);
        }
      }
      _config = config;

      final client = UdpSipClient(
        server: config.server,
        port: config.port,
        username: config.username,
        password: config.password,
        displayName: config.displayName,
        authUsername: config.authUsername,
        media: _media,
        expires: config.registerInterval,
        userAgent: config.userAgent,
        keepAliveInterval: Duration(seconds: config.keepAliveInterval),
        allowContactRewrite: config.allowContactRewrite,
      );
      client.onRegistrationStateChanged = (registered) {
        _isConnected = registered;
        _add(_connectionStateController, registered);
      };
      client.onIncomingCall = _onIncomingCall;
      client.onCallStateChanged = _onCallEvent;
      client.onError = (error) => _add(_errorController, error);
      _client = client;

      _wireAudio();
      SoundService.instance.initialize();
      await AudioPlayerService.instance.initialize();
      sipLog(
        '[SipHelper] Initialized for ${config.username}@'
        '${config.server}:${config.port}',
      );
    } catch (e) {
      _add(_errorController, 'Failed to initialize SIP: $e');
      rethrow;
    }
  }

  void _wireAudio() {
    if (_audioWired) return;
    _audioWired = true;
    RtpSession.instance.onRtpPayload = (Uint8List payload, int payloadType) {
      AudioPlayerService.instance.processAudioPacket(
        payload,
        payloadType: payloadType,
      );
    };
    MicrophoneService.instance.onAudioCaptured = (
      Uint8List encoded,
      int payloadType,
    ) {
      RtpSession.instance.sendAudio(encoded, payloadType);
    };
    MicrophoneService.instance.onRawAudioCaptured = (Uint8List pcm16) {
      AudioLevelService.instance.updateInputFromPcm16(pcm16);
    };
  }

  // ── Registration ───────────────────────────────────────────

  /// Register with the server.
  Future<void> connect() async {
    final client = _client;
    if (client == null) {
      throw StateError('SIP not initialized. Call initialize() first.');
    }
    try {
      await client.connect();
    } catch (e) {
      _add(_errorController, 'Failed to connect: $e');
      rethrow;
    }
  }

  /// Hang up all calls, un-register and close the socket.
  Future<void> disconnect() async {
    final client = _client;
    if (client == null) return;
    try {
      await client.unregister();
    } catch (_) {}
    if (_isConnected) {
      _isConnected = false;
      _add(_connectionStateController, false);
    }
  }

  /// Rebind the socket and register again, for example after the network
  /// changed (Wi-Fi to mobile data). Live calls are dropped.
  Future<void> reconnect() async {
    final client = _client;
    if (client == null) return;
    await client.disconnect();
    await client.connect();
  }

  // ── Calls ──────────────────────────────────────────────────

  /// Call [destination] (extension, number or `sip:` URI). Returns the
  /// Call-ID.
  Future<String> makeCall(String destination) async {
    final client = _client;
    if (client == null) throw StateError('SIP not initialized');
    if (!isConnected) throw StateError('Not registered to SIP server');
    try {
      if (autoHoldOtherCalls) await _holdOthers(null);
      await _prepareCallAudio();
      return await client.makeCall(destination);
    } catch (e) {
      _add(_errorController, 'Failed to make call: $e');
      await _deactivateIfIdle();
      rethrow;
    }
  }

  /// Answer a ringing incoming call.
  Future<void> answerCall(String callId) async {
    final client = _client;
    if (client == null) return;
    try {
      if (autoHoldOtherCalls) await _holdOthers(callId);
      if (autoTones) SoundService.instance.stopRinging();
      await _prepareCallAudio();
      await client.answerCall(callId);
      final call = _calls[callId];
      if (call != null && call.state == CallState.ringing) call.answer();
    } catch (e) {
      _add(_errorController, 'Failed to answer call: $e');
    }
  }

  /// Hang up, reject or cancel a call.
  Future<void> hangupCall(String callId) async {
    try {
      await _client?.hangupCall(callId);
    } catch (e) {
      _add(_errorController, 'Failed to hangup call: $e');
    }
  }

  /// Reject a ringing incoming call (same as [hangupCall]).
  Future<void> declineCall(String callId) => hangupCall(callId);

  /// Put a call on hold. Completes with true once the far end accepted.
  Future<bool> holdCall(String callId) async {
    final client = _client;
    if (client == null) return false;
    try {
      return await client.holdCall(callId);
    } catch (e) {
      _add(_errorController, 'Failed to hold call: $e');
      return false;
    }
  }

  /// Resume a held call. Completes with true once the far end accepted.
  Future<bool> unholdCall(String callId) async {
    final client = _client;
    if (client == null) return false;
    try {
      if (autoHoldOtherCalls) await _holdOthers(callId);
      return await client.unholdCall(callId);
    } catch (e) {
      _add(_errorController, 'Failed to unhold call: $e');
      return false;
    }
  }

  /// Blind-transfer an established call to [target]. Completes with true
  /// when the server accepted the transfer request.
  Future<bool> transferCall(String callId, String target) async {
    final client = _client;
    if (client == null) return false;
    try {
      return await client.transferCall(callId, target);
    } catch (e) {
      _add(_errorController, 'Failed to transfer call: $e');
      return false;
    }
  }

  /// Send DTMF digits (0-9, *, #, A-D) on an established call.
  Future<void> sendDtmf(String callId, String digits) async {
    try {
      await _client?.sendDtmf(callId, digits);
    } catch (e) {
      _add(_errorController, 'Failed to send DTMF: $e');
    }
  }

  // ── Audio controls ─────────────────────────────────────────

  /// Mute or unmute the microphone (silence is sent while muted).
  void setMuted(bool muted) => MicrophoneService.instance.setMuted(muted);

  bool get isMuted => MicrophoneService.instance.isMuted;

  /// Route call audio to the loudspeaker or back to the earpiece (Android
  /// and iOS).
  Future<void> setSpeakerphone(bool on) =>
      AudioPlatform.instance.session.setSpeakerphone(on);

  bool get isSpeakerphoneOn => AudioPlatform.instance.session.isSpeakerphoneOn;

  /// Ask for the microphone permission up front (Android and iOS). It is
  /// also requested automatically on the first call.
  Future<bool> requestMicrophonePermission() =>
      AudioPlatform.instance.session.requestMicrophonePermission();

  // ── Internals ──────────────────────────────────────────────

  Future<void> _prepareCallAudio() async {
    final session = AudioPlatform.instance.session;
    final granted = await session.requestMicrophonePermission();
    if (!granted) {
      _add(
        _errorController,
        'Microphone permission denied, the other side will not hear you',
      );
    }
    if (!_sessionActive) {
      _sessionActive = true;
      await session.activate();
    }
  }

  Future<void> _deactivateIfIdle() async {
    final busy = _calls.values.any(
      (c) =>
          c.state != CallState.ended &&
          !(c.direction == CallDirection.incoming &&
              c.state == CallState.ringing),
    );
    if (busy || !_sessionActive) return;
    _sessionActive = false;
    MicrophoneService.instance.setMuted(false);
    await AudioPlatform.instance.session.deactivate();
  }

  Future<void> _holdOthers(String? exceptCallId) async {
    final client = _client;
    if (client == null) return;
    for (final entry in client.activeCalls.entries) {
      final call = entry.value;
      if (entry.key == exceptCallId || !call.isConfirmed || call.isOnHold) {
        continue;
      }
      final ok = await client.holdCall(entry.key);
      if (!ok) {
        _add(
          _errorController,
          'Could not put ${call.remoteNumber} on hold, it is still live',
        );
      }
    }
  }

  void _onIncomingCall(String number, String? name, String callId) {
    final busy = _calls.values.any(
      (c) =>
          c.state == CallState.active ||
          c.state == CallState.onHold ||
          c.direction == CallDirection.outgoing,
    );
    final info = CallInfo(
      callerNumber: number,
      callerName: name,
      callId: callId,
      sessionId: callId.hashCode,
      state: CallState.ringing,
      direction: CallDirection.incoming,
    );
    _calls[callId] = info;
    if (autoTones && !busy) SoundService.instance.startRinging();
    _add(_incomingCallController, info);
  }

  void _onCallEvent(String callId, SipCallEvent event) {
    var call = _calls[callId];
    if (call == null && event == SipCallEvent.calling) {
      final sip = _client?.activeCalls[callId];
      call = CallInfo(
        callerNumber: sip?.remoteNumber ?? '',
        callId: callId,
        sessionId: callId.hashCode,
        state: CallState.ringing,
        direction: CallDirection.outgoing,
      );
      _calls[callId] = call;
    }

    switch (event) {
      case SipCallEvent.calling:
      case SipCallEvent.transferred:
        break;
      case SipCallEvent.ringing:
        if (autoTones && call?.direction == CallDirection.outgoing) {
          SoundService.instance.startRingback();
        }
      case SipCallEvent.confirmed:
        if (autoTones) SoundService.instance.stopRingback();
        if (call != null && call.state == CallState.ringing) call.answer();
      case SipCallEvent.held:
        call?.hold();
      case SipCallEvent.resumed:
        call?.resume();
      case SipCallEvent.remoteHeld:
      case SipCallEvent.remoteResumed:
        if (call != null) {
          call.isRemoteHold = event == SipCallEvent.remoteHeld;
          call.onStateChanged?.call(call);
        }
      case SipCallEvent.ended:
      case SipCallEvent.cancelled:
      case SipCallEvent.declined:
      case SipCallEvent.failed:
        _calls.remove(callId);
        call?.endCall();
        if (autoTones) {
          if (call?.direction == CallDirection.outgoing) {
            SoundService.instance.stopRingback();
          }
          final stillRinging = _calls.values.any(
            (c) =>
                c.direction == CallDirection.incoming &&
                c.state == CallState.ringing,
          );
          if (!stillRinging) SoundService.instance.stopRinging();
        }
        _deactivateIfIdle();
    }

    _add(_callStateController, '$callId:${event.legacyName}');
    _add(_callEventController, SipCallEventInfo(callId, event, call));
  }

  void _add<T>(StreamController<T> controller, T value) {
    if (!controller.isClosed) controller.add(value);
  }

  /// Un-register and close all streams. The helper cannot be used again
  /// afterwards.
  Future<void> dispose() async {
    await _client?.unregister();
    await _connectionStateController.close();
    await _incomingCallController.close();
    await _callStateController.close();
    await _callEventController.close();
    await _errorController.close();
  }
}

/// Default [SipMediaHandler]: [RtpSession] for transport,
/// [MicrophoneService] for capture, [AudioPlayerService] for playback.
class _DefaultMedia implements SipMediaHandler {
  RtpSession get _rtp => RtpSession.instance;

  @override
  Future<int?> prepare() async {
    try {
      await _rtp.initialize();
      await AudioPlayerService.instance.initialize();
      return _rtp.localPort;
    } catch (e) {
      sipLog('[SipHelper] RTP prepare failed: $e');
      return null;
    }
  }

  @override
  int? get localPort => _rtp.localPort;

  @override
  void setRemote(
    String host,
    int port, {
    required int payloadType,
    int? dtmfPayloadType,
  }) {
    _rtp.sendPayloadType = payloadType;
    _rtp.dtmfPayloadType = dtmfPayloadType;
    MicrophoneService.instance.payloadType = payloadType;
    _rtp.setRemoteEndpoint(host, port);
  }

  @override
  void setIgnoredEndpoints(Set<String> endpoints) {
    _rtp.otherLegEndpoints = endpoints;
  }

  @override
  Future<bool> startMicrophone() => MicrophoneService.instance.startCapture();

  @override
  void stopMicrophone() {
    MicrophoneService.instance.stopCapture();
  }

  @override
  void sendSilence() => _rtp.sendSilence();

  @override
  Future<void> sendDtmf(String digit, {int durationMs = 160}) =>
      _rtp.sendDtmf(digit, durationMs: durationMs);

  @override
  void release() {
    MicrophoneService.instance.stopCapture();
    _rtp.close();
    AudioPlayerService.instance.stop();
    AudioLevelService.instance.reset();
  }
}
