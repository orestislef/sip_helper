import 'package:test/test.dart';
import 'package:sip_helper/src/logging.dart';

void main() {
  group('Logging', () {
    test('sipLog does nothing when sipLogger is null', () {
      sipLogger = null;
      // Should not throw
      sipLog('test message');
    });

    test('sipLog calls sipLogger callback', () {
      String? captured;
      sipLogger = (msg) => captured = msg;

      sipLog('hello world');
      expect(captured, 'hello world');

      // Cleanup
      sipLogger = null;
    });

    test('sipLogger can be replaced', () {
      final messages = <String>[];

      sipLogger = (msg) => messages.add('A: $msg');
      sipLog('first');

      sipLogger = (msg) => messages.add('B: $msg');
      sipLog('second');

      expect(messages, ['A: first', 'B: second']);

      // Cleanup
      sipLogger = null;
    });
  });
}
