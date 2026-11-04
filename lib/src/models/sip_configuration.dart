/// SIP account configuration.
class SipConfiguration {
  final String server;
  final String username;
  final String password;
  final String displayName;
  final int port;

  /// Only UDP is supported.
  final String transport;
  final bool autoRegister;

  /// Registration lifetime in seconds, sent as `Expires`. The registration
  /// is refreshed automatically before it runs out.
  final int registerInterval;

  /// Username for digest authentication when it differs from the extension
  /// (common with SIP providers). Empty means [username].
  final String authUsername;

  /// Value of the User-Agent header.
  final String userAgent;

  /// Seconds between NAT keep-alives sent to the server while registered.
  /// Mobile networks drop idle UDP mappings after 30 to 60 seconds, after
  /// which incoming calls no longer arrive. 0 disables keep-alives.
  final int keepAliveInterval;

  /// Put the public address the server reports (Via `received`/`rport`)
  /// in Contact, Via and SDP and register again with it. Same as "Allow IP
  /// rewrite" in MicroSIP. Turn it on behind NAT when the server does not
  /// rewrite contacts itself.
  final bool allowContactRewrite;

  const SipConfiguration({
    required this.server,
    required this.username,
    required this.password,
    this.displayName = '',
    this.port = 5060,
    this.transport = 'UDP',
    this.autoRegister = true,
    this.registerInterval = 600,
    this.authUsername = '',
    this.userAgent = 'IQ-SIP',
    this.keepAliveInterval = 25,
    this.allowContactRewrite = false,
  });

  /// Create from JSON
  factory SipConfiguration.fromJson(Map<String, dynamic> json) {
    return SipConfiguration(
      server: json['server'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      port: json['port'] as int? ?? 5060,
      transport: json['transport'] as String? ?? 'UDP',
      autoRegister: json['autoRegister'] as bool? ?? true,
      registerInterval: json['registerInterval'] as int? ?? 600,
      authUsername: json['authUsername'] as String? ?? '',
      userAgent: json['userAgent'] as String? ?? 'IQ-SIP',
      keepAliveInterval: json['keepAliveInterval'] as int? ?? 25,
      allowContactRewrite: json['allowContactRewrite'] as bool? ?? false,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'server': server,
      'username': username,
      'password': password,
      'displayName': displayName,
      'port': port,
      'transport': transport,
      'autoRegister': autoRegister,
      'registerInterval': registerInterval,
      'authUsername': authUsername,
      'userAgent': userAgent,
      'keepAliveInterval': keepAliveInterval,
      'allowContactRewrite': allowContactRewrite,
    };
  }

  /// Create a copy with updated fields
  SipConfiguration copyWith({
    String? server,
    String? username,
    String? password,
    String? displayName,
    int? port,
    String? transport,
    bool? autoRegister,
    int? registerInterval,
    String? authUsername,
    String? userAgent,
    int? keepAliveInterval,
    bool? allowContactRewrite,
  }) {
    return SipConfiguration(
      server: server ?? this.server,
      username: username ?? this.username,
      password: password ?? this.password,
      displayName: displayName ?? this.displayName,
      port: port ?? this.port,
      transport: transport ?? this.transport,
      autoRegister: autoRegister ?? this.autoRegister,
      registerInterval: registerInterval ?? this.registerInterval,
      authUsername: authUsername ?? this.authUsername,
      userAgent: userAgent ?? this.userAgent,
      keepAliveInterval: keepAliveInterval ?? this.keepAliveInterval,
      allowContactRewrite: allowContactRewrite ?? this.allowContactRewrite,
    );
  }

  /// Check if configuration is valid
  bool get isValid {
    return server.isNotEmpty && username.isNotEmpty && password.isNotEmpty;
  }

  /// Get SIP URI
  String get uri => 'sip:$username@$server';
}
