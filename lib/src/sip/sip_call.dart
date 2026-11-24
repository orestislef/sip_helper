/// State of one SIP dialog (an active or ringing call).
class SipCall {
  final String callId;

  /// From header value without tag. For incoming calls this is the remote
  /// party, for outgoing calls it is us.
  final String fromHeader;

  /// To header value without tag. For incoming calls this is us, for
  /// outgoing calls it is the remote party.
  final String toHeader;

  /// Remote Contact header value, if known.
  String? contact;
  String? localTag;
  String? remoteTag;
  final bool isIncoming;

  /// Remote party number (user part of the remote URI).
  final String remoteNumber;

  /// Remote party display name, if any.
  final String? remoteName;

  /// Whether the call dialog is fully established (200 OK exchanged).
  bool isConfirmed = false;

  /// Branch used in the Via of our latest initial INVITE (needed for CANCEL
  /// and for the ACK of a non-2xx final response).
  String? inviteBranch;

  /// CSeq number of our latest initial INVITE (needed for CANCEL).
  int? inviteCSeq;

  /// Our CSeq sequence inside this dialog. RFC 3261 8.1.1.5: CSeq increases
  /// per dialog, not globally. Every in-dialog request we send (re-INVITE,
  /// BYE, REFER, INFO) pre-increments it.
  int dialogCseq;

  /// Whether we placed this call on hold.
  bool isOnHold = false;

  /// Whether the remote side placed us on hold.
  bool isRemoteHold = false;

  /// Remote RTP host from the latest SDP.
  String? remoteRtpHost;

  /// Remote RTP port from the latest SDP.
  int? remoteRtpPort;

  /// Negotiated G.711 payload type (8 = PCMA, 0 = PCMU).
  int payloadType = 8;

  /// Negotiated RFC 4733 telephone-event payload type, null when the remote
  /// did not offer one (DTMF then goes out as SIP INFO).
  int? dtmfPayloadType;

  /// Request-URI for in-dialog requests (the remote Contact URI).
  String? remoteTarget;

  /// Route set learned from Record-Route, in the order to put in requests.
  List<String> routeSet = const [];

  /// We sent the SDP offer in a 200 OK (the INVITE had no SDP), so the
  /// answer arrives in the ACK.
  bool answerExpectedInAck = false;

  /// SDP origin session id and version for our side of this call.
  final int sdpSessionId;
  int sdpVersion = 0;

  SipCall({
    required this.callId,
    required this.fromHeader,
    required this.toHeader,
    this.contact,
    this.localTag,
    this.remoteTag,
    this.isIncoming = false,
    this.inviteBranch,
    this.inviteCSeq,
    this.dialogCseq = 1,
    String? remoteNumber,
    this.remoteName,
    int? sdpSessionId,
  }) : remoteNumber = remoteNumber ?? '',
       sdpSessionId =
           sdpSessionId ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// `host:port` of the remote RTP endpoint, or null.
  String? get remoteRtp =>
      remoteRtpHost != null && remoteRtpPort != null
          ? '$remoteRtpHost:$remoteRtpPort'
          : null;

  /// Our own side of the dialog (From for outgoing, To for incoming).
  String get localHeader => isIncoming ? toHeader : fromHeader;

  /// The remote side of the dialog (To for outgoing, From for incoming).
  String get remoteHeader => isIncoming ? fromHeader : toHeader;
}
