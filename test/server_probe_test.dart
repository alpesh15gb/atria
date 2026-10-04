import 'package:atria/core/api/server_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Settings "Test connection" button exists to tell apart three things that
/// look identical from a browser tab: the Apex Books API answered, *something else*
/// answered, and nothing answered. Only the first is a pass.
///
/// This is not hypothetical. `api.apexbooks.in` used to be served by a different
/// server that returned HTTP 200 with exactly `{"status":"ok"}`, so a check that
/// accepted a healthy status would have reported a clean connection straight
/// through the wrong application.
void main() {
  group('describeHealthBody', () {
    test('accepts the Apex Books API payload and names its version', () {
      final result = ServerProbe.describeHealthBody(
        '{"status":"ok","version":"0.1.0","uptimeSeconds":42}',
      );
      expect(result.ok, isTrue);
      expect(result.message, contains('0.1.0'));
    });

    test('rejects a healthy status with no version — a different app', () {
      // Verbatim what the predecessor server returned.
      final result = ServerProbe.describeHealthBody('{"status":"ok"}');
      expect(result.ok, isFalse);
      expect(result.message, contains('version'));
    });

    test('rejects a version that is not a string', () {
      final result =
          ServerProbe.describeHealthBody('{"status":"ok","version":1}');
      expect(result.ok, isFalse);
    });

    test('rejects a non-JSON reply, such as another server\'s 404 page', () {
      final result = ServerProbe.describeHealthBody('404 page not found\n');
      expect(result.ok, isFalse);
      expect(result.message, contains('not JSON'));
    });

    test('rejects a JSON reply that is healthy but not ours', () {
      final result = ServerProbe.describeHealthBody('{"error":"nope"}');
      expect(result.ok, isFalse);
      expect(result.message, contains('not the Apex Books API'));
    });

    test('rejects a JSON array, which some proxies return', () {
      expect(ServerProbe.describeHealthBody('[]').ok, isFalse);
    });

    test('rejects an unhealthy status even with our version', () {
      final result = ServerProbe.describeHealthBody(
        '{"status":"schema_missing","version":"0.1.0"}',
      );
      expect(result.ok, isFalse);
    });
  });

  group('check', () {
    test('an empty address fails without attempting a request', () async {
      final result = await ServerProbe.check('   ');
      expect(result.ok, isFalse);
      expect(result.message, contains('Enter a server address'));
    });
  });
}
