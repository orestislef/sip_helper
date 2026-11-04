/// Windows registration hook for the Flutter plugin system.
///
/// Windows audio is pure Dart (WinMM through `dart:ffi`) and is picked up by
/// [AudioPlatform] at runtime, so there is nothing to register.
class SipHelperWindows {
  SipHelperWindows._();

  /// Called by the Flutter tool's generated plugin registrant.
  static void registerWith() {}
}
