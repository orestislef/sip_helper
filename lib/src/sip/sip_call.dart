/// Active call information
class SipCall {
  final String callId;
  final String fromHeader;   // Full From header value (without tag)
  final String toHeader;     // Full To header value (without tag)
  final String? contact;
  String? localTag;
  String? remoteTag;
  final bool isIncoming;

  SipCall({
    required this.callId,
    required this.fromHeader,
    required this.toHeader,
    this.contact,
    this.localTag,
    this.remoteTag,
    this.isIncoming = false,
  });
}
