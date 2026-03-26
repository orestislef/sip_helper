/// Active call information
class SipCall {
  final String callId;
  final String fromHeader;   // Full From header value (without tag)
  final String toHeader;     // Full To header value (without tag)
  final String? contact;
  String? localTag;
  String? remoteTag;
  final bool isIncoming;

  /// Whether the call dialog is fully established (200 OK exchanged).
  bool isConfirmed = false;

  /// Branch used in the INVITE Via header (needed for CANCEL).
  String? inviteBranch;

  /// CSeq number used in the INVITE (needed for CANCEL).
  int? inviteCSeq;

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
  });
}
