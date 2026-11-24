/// Call lifecycle events emitted by [UdpSipClient] and [SipHelper].
enum SipCallEvent {
  /// Outgoing INVITE sent, waiting for an answer.
  calling,

  /// The far end is ringing (180) or sent call progress (183).
  ringing,

  /// The call is established (200 OK + ACK).
  confirmed,

  /// Our hold request was accepted, the call is on hold.
  held,

  /// Our resume request was accepted, the call is live again.
  resumed,

  /// The far end put us on hold.
  remoteHeld,

  /// The far end took us off hold.
  remoteResumed,

  /// A blind transfer we started was completed by the PBX.
  transferred,

  /// The call ended normally (BYE from either side, or local hangup).
  ended,

  /// The caller hung up before the call was answered (CANCEL).
  cancelled,

  /// The far end rejected our call (busy or declined).
  declined,

  /// The call could not be set up (not found, unavailable, auth failure,
  /// no answer from the server, unsupported media, ...).
  failed;

  /// True for events after which the call no longer exists.
  bool get isTerminal =>
      this == ended || this == cancelled || this == declined || this == failed;

  /// The upper case name used by the legacy `callId:STATE` string stream.
  String get legacyName => switch (this) {
    calling => 'CALLING',
    ringing => 'RINGING',
    confirmed => 'CONFIRMED',
    held => 'HELD',
    resumed => 'RESUMED',
    remoteHeld => 'REMOTE_HELD',
    remoteResumed => 'REMOTE_RESUMED',
    transferred => 'TRANSFERRED',
    ended => 'ENDED',
    cancelled => 'CANCELED',
    declined => 'DECLINED',
    failed => 'FAILED',
  };
}
