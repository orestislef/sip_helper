/// Log callback type for sip_helper package.
typedef SipLogCallback = void Function(String message);

/// Global logger. Set this to receive log output from sip_helper.
/// Example: `sipLogger = print;`
SipLogCallback? sipLogger;

/// Internal logging function used throughout the package.
void sipLog(String message) {
  sipLogger?.call(message);
}
