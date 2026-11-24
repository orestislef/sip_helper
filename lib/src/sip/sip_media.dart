/// The audio side of a call, as seen by [UdpSipClient].
///
/// The SIP client decides when audio starts, stops and where it goes; an
/// implementation of this interface does the actual RTP and device work.
/// [SipHelper] wires a default one built on [RtpSession] and
/// [MicrophoneService]. Tests and custom stacks can supply their own.
abstract class SipMediaHandler {
  /// Make sure an RTP socket is bound and return its local port, or null when
  /// it could not be opened. Must be idempotent: the port has been
  /// advertised in SDP, rebinding mid-call would make the call silent.
  Future<int?> prepare();

  /// Local RTP port, or null when no socket is open.
  int? get localPort;

  /// Send audio to [host]:[port] with [payloadType] (8 = PCMA, 0 = PCMU).
  /// [dtmfPayloadType] is the negotiated telephone-event payload, if any.
  void setRemote(
    String host,
    int port, {
    required int payloadType,
    int? dtmfPayloadType,
  });

  /// RTP endpoints (`host:port`) of the other, held calls. Their packets
  /// (music on hold) must never reach the speaker.
  void setIgnoredEndpoints(Set<String> endpoints);

  /// Start the microphone. Returns false when the device could not be
  /// opened (for example the permission was denied).
  Future<bool> startMicrophone();

  /// Stop the microphone.
  void stopMicrophone();

  /// Send one packet of silence, which opens NAT and firewall pinholes so
  /// the remote audio can reach us.
  void sendSilence();

  /// Send one DTMF digit as RFC 4733 telephone-event packets.
  Future<void> sendDtmf(String digit, {int durationMs = 160});

  /// Release the RTP socket and audio devices (no call left).
  void release();
}
