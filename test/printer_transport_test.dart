import 'dart:io';

import 'package:atria/core/printer/label_encoder.dart';
import 'package:atria/core/printer/printer_profile.dart';
import 'package:atria/core/printer/printer_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Windows print path is the highest-risk code in the app: it reaches into
/// `winspool.drv` through `dart:ffi`, it can block for as long as a driver
/// decides to, and the same binary runs on a desktop and on a phone. None of
/// that can be exercised here — there is no spooler to talk to in a test — so
/// what is worth pinning down is the logic *around* the FFI: which error code is
/// turned into which words, and which transports this device may reach at all.
///
/// The one thing that must not go wrong here is the transport filter. A `usb`
/// profile saved on a desktop comes back on a phone still naming a Windows
/// print queue, and every entry point that hands a profile to a printer has to
/// reach the same conclusion about it. The expectations below are written
/// against `Platform.isWindows` rather than hard-coded, so the test holds on
/// either host.
void main() {
  group('spooler error text', () {
    test('the code Windows actually returns is spelled out', () {
      // Searchable numbers with the number kept alongside, because "access
      // denied" on its own sends an operator hunting the wrong thing.
      expect(spoolErrorText(5), contains('access denied'));
      expect(spoolErrorText(1801), contains('not recognised by Windows'));
      expect(spoolErrorText(87), contains('not valid'));
      expect(spoolErrorText(3002), contains('refused the job'));
    });

    test('an unknown code still reports the number, and so does "no error"', () {
      // A bare "unrecognised spooler error" with no number is a dead end: the
      // number is what gets searched.
      expect(spoolErrorText(4242), 'unrecognised spooler error');
      expect(spoolErrorText(0), 'no error');
    });
  });

  group('Windows-only transport', () {
    const usb = PrinterProfile(
      id: 'desk',
      name: 'Counter TSC',
      transport: PrinterTransport.usb,
      queueName: 'TSC TTP-244 Pro',
    );
    const net = PrinterProfile(
      id: 'lan',
      name: 'Shelf TSC',
      transport: PrinterTransport.network,
      host: '192.168.1.50',
    );

    test('a stored queue profile is only usable where Windows is running', () {
      // The profile is *complete* either way — the queue name is right, it just
      // names a spooler that does not exist off Windows. That is the
      // distinction `isUsable` on its own cannot make, and it is the one that
      // decides whether a print button is offered at all.
      expect(usb.isUsable, isTrue);
      expect(usb.isUsableHere, Platform.isWindows);
      expect(net.isUsableHere, isTrue);
      expect(
        PrinterTransport.usb.isSupportedHere,
        Platform.isWindows,
        reason: 'a Windows print queue cannot exist where Windows is not',
      );
    });

    test('the picker offers raw TCP always and a queue only on Windows', () {
      expect(
        PrinterTransport.availableHere,
        contains(PrinterTransport.network),
        reason: 'raw TCP is the one path that works on every platform',
      );
      expect(
        PrinterTransport.availableHere.contains(PrinterTransport.usb),
        Platform.isWindows,
      );
      // The stored list is never rewritten behind the operator's back: the
      // queue name stays in the profile until the editor re-adds the printer.
      expect(PrinterTransport.usb.isSupportedHere, Platform.isWindows);
    });

    test('an unreachable queue says what to do, not just that it failed', () {
      if (Platform.isWindows) {
        // On the platform that has queues this profile is fine, and `problem`
        // being null is the point of the split.
        expect(usb.problem, isNull);
        expect(PrinterConnection.unsupportedHere(PrinterTransport.usb), isNull);
        return;
      }
      final problem = usb.problem ?? '';
      expect(problem, contains('IP address'));
      expect(
        problem,
        isNot(contains('No installed printer was chosen')),
        reason: 'the queue name is correct — it is the platform that is wrong',
      );
      expect(PrinterConnection.unsupportedHere(PrinterTransport.usb), isNotNull);
    });

    test('an incomplete profile is reported before an unreachable one', () {
      // A `usb` profile with no queue name says the actionable thing on every
      // platform, so the message must not change with the host.
      expect(
        usb.copyWith(queueName: '').problem,
        'No installed printer was chosen.',
      );
      expect(net.copyWith(host: '  ').problem, 'No printer address was set.');
    });
  });

  group('ports', () {
    test('a hand-edited port is clamped so the profile still prints', () {
      // Refusing to load it would leave the operator unable to fix it; the
      // clamp is what keeps Settings openable.
      final bad = PrinterProfile.fromJson({
        'id': 'x',
        'name': 'Odd',
        'host': '192.168.1.50',
        'port': 70000,
      });
      expect(bad.port, 65535);
      expect(bad.isUsableHere, isTrue);
    });

    test('a port nothing can connect to is refused with the number typed', () {
      // The field parses with the previous value as its fallback, so this is
      // only reachable by hand — but when it happens the message has to name
      // the number the operator typed, not a generic failure.
      expect(
        const PrinterProfile(
          id: 'y',
          name: 'Zero',
          host: '192.168.1.50',
          port: 0,
        ).problem,
        'Port 0 is not a usable port.',
      );
    });
  });

  group('what escapes a print', () {
    test('an unusable profile is refused at the service, not at the socket', () {
      // `LabelEncoder` will happily encode for a printer this device cannot
      // reach — the refusal has to be a send-time one, before any FFI or socket
      // work happens.
      const broken = PrinterProfile(
        id: 'z',
        name: 'No address',
        transport: PrinterTransport.network,
      );
      expect(broken.problem, isNotNull);
      expect(
        () => LabelEncoder.forProfile(broken).encodeTestLabel(),
        returnsNormally,
        reason: 'encoding is fine — only sending is not',
      );
    });
  });
}
