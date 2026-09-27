import 'package:atria/core/services/upi_qr.dart';
import 'package:atria/core/utils/whatsapp_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpiQr.upiUri', () {
    test('builds a parsable upi://pay intent with amount and reference', () {
      final uri = UpiQr.upiUri(
        payeeVpa: 'firm@upi',
        payeeName: 'Acme Traders',
        amount: '1234.50',
        note: 'Invoice INV/2026-27/001',
        invoiceNumber: 'INV/2026-27/001',
      );
      expect(uri, startsWith('upi://pay?'));
      expect(uri, contains('pa=firm%40upi'));
      expect(uri, contains('pn=Acme%20Traders'));
      expect(uri, contains('am=1234.50'));
      expect(uri, contains('cu=INR'));
      expect(uri, contains('tr=INV%2F2026-27%2F001'));
    });

    test('omits optional note and reference when empty', () {
      final uri = UpiQr.upiUri(
        payeeVpa: 'firm@upi',
        payeeName: 'Acme',
        amount: '10.00',
      );
      expect(uri, isNot(contains('tn=')));
      expect(uri, isNot(contains('tr=')));
    });

    test('UpiQr.widget returns null for empty data', () {
      expect(UpiQr.widget(''), isNull);
    });
  });

  group('WhatsAppLinks.chat', () {
    test('prefixes the India country code and URL-encodes the message', () {
      final uri = WhatsAppLinks.chat('9876543210', message: 'Hi there');
      expect(uri.toString(), startsWith('https://wa.me/919876543210'));
      expect(uri.toString(), contains(Uri.encodeComponent('Hi there')));
    });

    test('strips non-digits from the phone', () {
      final uri = WhatsAppLinks.chat('+91 98765 43210');
      expect(uri.toString(), startsWith('https://wa.me/919876543210'));
    });

    test('no query string without a message', () {
      final uri = WhatsAppLinks.chat('9876543210');
      expect(uri.toString(), 'https://wa.me/919876543210');
    });
  });
}
