/// Call state enum
enum CallState {
  ringing,
  active,
  onHold,
  ended,
}

/// Call direction
enum CallDirection {
  incoming,
  outgoing,
}

/// Call information model for SIP calls
class CallInfo {
  final String callerNumber;
  final String? callerName;
  final DateTime startTime;
  DateTime? endTime;
  CallState state;
  final int? sessionId;
  final String? callId;
  final CallDirection direction;

  /// Optional callback invoked whenever the call state changes.
  void Function(CallInfo)? onStateChanged;

  CallInfo({
    required this.callerNumber,
    this.callerName,
    DateTime? startTime,
    this.endTime,
    this.state = CallState.ringing,
    this.sessionId,
    this.callId,
    this.direction = CallDirection.incoming,
    this.onStateChanged,
  }) : startTime = startTime ?? DateTime.now();

  /// Get duration of the call
  Duration get duration {
    final end = endTime ?? DateTime.now();
    return end.difference(startTime);
  }

  /// Get formatted duration string (MM:SS)
  String get durationFormatted {
    final dur = duration;
    final minutes = dur.inMinutes;
    final seconds = dur.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Get display name (name or number)
  String get displayName => callerName ?? callerNumber;

  /// Get state as text
  String get stateText {
    switch (state) {
      case CallState.ringing:
        return 'Ringing';
      case CallState.active:
        return 'Active';
      case CallState.onHold:
        return 'On Hold';
      case CallState.ended:
        return 'Ended';
    }
  }

  /// Set call state and notify listeners
  void setState(CallState newState) {
    state = newState;
    if (newState == CallState.ended && endTime == null) {
      endTime = DateTime.now();
    }
    onStateChanged?.call(this);
  }

  void endCall() => setState(CallState.ended);
  void answer() => setState(CallState.active);
  void hold() => setState(CallState.onHold);
  void resume() => setState(CallState.active);
}
