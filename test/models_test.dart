import 'package:test/test.dart';
import 'package:sip_helper/src/models/sip_configuration.dart';
import 'package:sip_helper/src/models/call_info.dart';

void main() {
  group('SipConfiguration', () {
    test('creates with required fields', () {
      final config = SipConfiguration(
        server: 'pbx.example.com',
        username: '1001',
        password: 'secret',
      );
      expect(config.server, 'pbx.example.com');
      expect(config.username, '1001');
      expect(config.password, 'secret');
      expect(config.port, 5060);
      expect(config.transport, 'UDP');
      expect(config.isValid, true);
    });

    test('isValid returns false for empty fields', () {
      final config = SipConfiguration(
        server: '',
        username: '1001',
        password: 'secret',
      );
      expect(config.isValid, false);
    });

    test('uri returns correct SIP URI', () {
      final config = SipConfiguration(
        server: 'pbx.example.com',
        username: '1001',
        password: 'secret',
      );
      expect(config.uri, 'sip:1001@pbx.example.com');
    });

    test('toJson and fromJson roundtrip', () {
      final config = SipConfiguration(
        server: 'pbx.example.com',
        username: '1001',
        password: 'secret',
        displayName: 'Test User',
        port: 5080,
      );

      final json = config.toJson();
      final restored = SipConfiguration.fromJson(json);

      expect(restored.server, config.server);
      expect(restored.username, config.username);
      expect(restored.password, config.password);
      expect(restored.displayName, config.displayName);
      expect(restored.port, config.port);
    });

    test('copyWith creates modified copy', () {
      final config = SipConfiguration(
        server: 'pbx.example.com',
        username: '1001',
        password: 'secret',
      );

      final modified = config.copyWith(port: 5080, displayName: 'New Name');
      expect(modified.port, 5080);
      expect(modified.displayName, 'New Name');
      expect(modified.server, 'pbx.example.com');
    });
  });

  group('CallInfo', () {
    test('creates with defaults', () {
      final call = CallInfo(callerNumber: '1002');
      expect(call.callerNumber, '1002');
      expect(call.state, CallState.ringing);
      expect(call.direction, CallDirection.incoming);
      expect(call.displayName, '1002');
    });

    test('displayName prefers callerName', () {
      final call = CallInfo(
        callerNumber: '1002',
        callerName: 'John',
      );
      expect(call.displayName, 'John');
    });

    test('setState updates state and calls callback', () {
      bool callbackCalled = false;
      final call = CallInfo(
        callerNumber: '1002',
        onStateChanged: (_) => callbackCalled = true,
      );

      call.setState(CallState.active);
      expect(call.state, CallState.active);
      expect(callbackCalled, true);
    });

    test('endCall sets state and endTime', () {
      final call = CallInfo(callerNumber: '1002');
      expect(call.endTime, isNull);

      call.endCall();
      expect(call.state, CallState.ended);
      expect(call.endTime, isNotNull);
    });

    test('durationFormatted returns MM:SS', () {
      final call = CallInfo(
        callerNumber: '1002',
        startTime: DateTime.now().subtract(Duration(minutes: 2, seconds: 30)),
      );
      // Should be approximately "02:30"
      expect(call.durationFormatted, matches(RegExp(r'0[2-3]:\d{2}')));
    });

    test('stateText returns human-readable text', () {
      final call = CallInfo(callerNumber: '1002');
      expect(call.stateText, 'Ringing');

      call.setState(CallState.active);
      expect(call.stateText, 'Active');

      call.setState(CallState.onHold);
      expect(call.stateText, 'On Hold');

      call.endCall();
      expect(call.stateText, 'Ended');
    });
  });
}
