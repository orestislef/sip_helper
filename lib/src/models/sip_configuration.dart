/// SIP configuration model
class SipConfiguration {
  final String server;
  final String username;
  final String password;
  final String displayName;
  final int port;
  final String transport; // UDP, TCP, TLS
  final bool autoRegister;
  final int registerInterval; // seconds

  const SipConfiguration({
    required this.server,
    required this.username,
    required this.password,
    this.displayName = '',
    this.port = 5060,
    this.transport = 'UDP',
    this.autoRegister = true,
    this.registerInterval = 600,
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
    );
  }

  /// Check if configuration is valid
  bool get isValid {
    return server.isNotEmpty && username.isNotEmpty && password.isNotEmpty;
  }

  /// Get SIP URI
  String get uri => 'sip:$username@$server';
}
