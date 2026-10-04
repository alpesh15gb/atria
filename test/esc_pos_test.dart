import 'dart:convert';

import 'package:atria/core/printer/printer_service.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A receipt is printed on narrow paper with a fixed font, so the two things
/// that can go wrong are silent: a line wider than the roll (the printer drops
/// the overflow) and a character the printer's code page cannot render.
///
/// Both are layout, not hardware, which is why they are testable here. The
/// layout is exposed as text lines on purpose — reading the layout beats
/// decoding bytes in a test, and it is the same list a preview would render.
void main() {
  ReceiptDocument sample({
    String firmName = 'Shri Balaji Traders',
    String itemName = 'Cement bag 50 kg',
    String? hsn,
    String quantityText = '2 bag',
    String rateText = 'Rs.500.00',
    String amount = 'Rs.1,000.00',
  }) =>
      ReceiptDocument(
        firmName: firmName,
        title: 'Tax invoice',
        number: 'INV-001',
        dateLine: '30 Sep 2026',
        firmGstin: '29ABCDE1234F1Z5',
        firmAddress: '12 MG Road, Bengaluru, 560001',
        firmPhone: '9876543210',
        partyName: 'Ravi Kumar',
        items: [
          ReceiptItemLine(
            name: itemName,
            hsn: hsn,
            quantityText: quantityText,
            rateText: rateText,
            amountText: amount,
          ),
        ],
        totals: const [
          ReceiptTotalLine('Taxable', 'Rs.1,000.00'),
          ReceiptTotalLine('CGST 9%', 'Rs.90.00'),
          ReceiptTotalLine('TOTAL', 'Rs.1,180.00', emphasise: true),
        ],
        paymentLine: 'Pay by UPI: shop@upi',
        footerLine: 'Thank you for your business',
      );

  group('layout', () {
    test('every line fits the roll it is being printed on', () {
      for (final columns in [EscPosEncoder.columns58, EscPosEncoder.columns80]) {
        final lines = EscPosEncoder(columns: columns).textLines(sample());
        for (final line in lines) {
          expect(
            line.length <= columns,
            true,
            reason: '"$line" is ${line.length} chars on a $columns-column roll',
          );
        }
        // The rule is exactly the paper width, which is what makes it read as a
        // rule rather than a stray line.
        expect(lines, contains('-' * columns));
      }
    });

    test('the rupee glyph is folded to Rs. for a printer without one', () {
      final lines = EscPosEncoder(columns: 32).textLines(
        sample(amount: '₹1,00,000.00'),
      );
      expect(lines.any((l) => l.contains('₹')), false);
      expect(lines.any((l) => l.contains('Rs.1,00,000.00')), true);
    });

    test('the amount sits at the right edge of its own line', () {
      final lines = EscPosEncoder(columns: 32).textLines(sample());
      // The item's amount is right-aligned: no amount can be followed by
      // anything, or a customer reads the wrong column.
      final amountLine = lines.firstWhere((l) => l.trimRight().endsWith('1,000.00'));
      expect(amountLine.length, 32);
      expect(amountLine.endsWith('Rs.1,000.00'), true);
    });

    test('a long item name wraps instead of running off the roll', () {
      final lines = EscPosEncoder(columns: 32).textLines(
        sample(itemName: 'Vitrified floor tile 600x600 mm polished ivory'),
      );
      expect(
        lines.any((l) => l.contains('Vitrified floor tile')),
        true,
      );
      expect(lines.any((l) => l.contains('ivory')), true);
      for (final line in lines) {
        expect(line.length <= 32, true);
      }
    });

    test('an item line too wide for one row puts the amount on its own row', () {
      final lines = EscPosEncoder(columns: 32).textLines(sample(
        hsn: '25232910',
        quantityText: '12 bag',
        rateText: 'Rs.1,234.56',
        amount: 'Rs.14,814.72',
      ));
      final detailIndex =
          lines.indexWhere((l) => l.startsWith('HSN 25232910'));
      expect(detailIndex >= 0, true);
      // The row after the detail is the amount, right-aligned on its own line.
      final amountLine = lines[detailIndex + 1];
      expect(amountLine.trim(), 'Rs.14,814.72');
      expect(amountLine.length, 32);
    });

    test('a duplicate is labelled so a reprint cannot pass for the original',
        () {
      final encoder = EscPosEncoder(columns: 32);
      final doc = ReceiptDocument(
        firmName: 'Shri Balaji Traders',
        title: 'Tax invoice',
        number: 'INV-001',
        dateLine: '30 Sep 2026',
        isReprint: true,
      );
      expect(encoder.textLines(doc), contains('*** DUPLICATE ***'));
    });

    test('a Devanagari shop name prints as placeholders, not as nothing', () {
      final lines = EscPosEncoder(columns: 32).textLines(
        sample(firmName: 'श्री बालाजी'),
      );
      // A printer with the right code page can be added later; losing the name
      // of the business on its own receipt is not an acceptable fallback.
      expect(lines.first.trim(), isNotEmpty);
      expect(lines.first.contains('?'), true);
    });
  });

  group('bytes', () {
    test('starts with an initialise and ends with a cut', () {
      final bytes = EscPosEncoder(columns: 32).encode(sample());
      expect(bytes.take(2).toList(), [0x1B, 0x40]);
      // GS V 1 — a partial cut, so the slip stays in the printer.
      expect(_contains(bytes, [0x1D, 0x56, 0x01]), true);
    });

    test('the shop name is printed double height and bold', () {
      final bytes = EscPosEncoder(columns: 32).encode(sample());
      final text = latin1.decode(bytes, allowInvalid: true);
      expect(_contains(bytes, [0x1B, 0x45, 0x01]), true); // bold on
      expect(_contains(bytes, [0x1D, 0x21, 0x11]), true); // double size
      expect(text, contains('Shri Balaji Traders'));
    });

    test('cutting and the drawer are each one switch', () {
      final plain = EscPosEncoder(columns: 32, cut: false).encode(sample());
      expect(_contains(plain, [0x1D, 0x56, 0x01]), false);

      final drawer = EscPosEncoder(
        columns: 32,
        openDrawer: true,
      ).encode(sample());
      // ESC p 0 25 250 — the pulse a drawer's solenoid expects.
      expect(_contains(drawer, [0x1B, 0x70, 0x00, 0x19, 0xFA]), true);

      final noDrawer = EscPosEncoder(columns: 32).encode(sample());
      expect(_contains(noDrawer, [0x1B, 0x70]), false);
    });

    test('a test receipt exercises the same encoder', () {
      final lines = EscPosEncoder(
        columns: 48,
        openDrawer: true,
      ).textLinesForTest();
      expect(lines.any((l) => l.contains('TEST PRINT')), true);
      expect(lines.any((l) => l.contains('48')), true);
      expect(lines.any((l) => l.contains('drawer')), true);
    });
  });

  group('printer profiles', () {
    test('a receipt profile survives a settings round trip', () {
      final profile = PrinterProfile(
        id: 'p1',
        name: 'Till',
        kind: PrinterKind.receipt,
        transport: PrinterTransport.network,
        host: '192.168.1.60',
        paperWidthMm: 80,
        cutPaper: false,
        openDrawer: true,
      );
      final restored = PrinterProfile.parseList(
        PrinterProfile.encodeList([profile]),
      ).single;

      expect(restored.kind, PrinterKind.receipt);
      expect(restored.paperWidthMm, 80);
      expect(restored.cutPaper, false);
      expect(restored.openDrawer, true);
      expect(restored.host, '192.168.1.60');
    });

    test('a profile saved before receipts existed is still a label printer',
        () {
      // Exactly what an older version wrote: no kind, no paper width.
      final legacy = jsonEncode([
        {
          'id': 'p1',
          'name': 'Counter TSC',
          'brand': 'tsc',
          'transport': 'network',
          'host': '192.168.1.50',
          'port': 9100,
          'dpi': 203,
          'labelWidthMm': 50,
          'labelHeightMm': 25,
        }
      ]);
      final restored = PrinterProfile.parseList(legacy).single;

      expect(restored.kind, PrinterKind.label);
      expect(restored.paperWidthMm, 58);
      expect(restored.cutPaper, true);
      expect(restored.openDrawer, false);
      expect(restored.labelWidthMm, 50);
    });

    test('an unusable roll width falls back to one the printer has', () {
      final odd = PrinterProfile.parseList(jsonEncode([
        {
          'id': 'p1',
          'name': 'Odd roll',
          'kind': 'receipt',
          'paperWidthMm': 76,
        }
      ])).single;
      // 76 mm would pick the 80 mm column count and print totals past the edge.
      expect(odd.paperWidthMm, 58);
    });

    test('the registry picks the right printer for each job', () async {
      final db = AppDatabase.test(NativeDatabase.memory());
      addTearDown(db.close);
      final registry = PrinterRegistry(db);
      await registry.upsert(PrinterProfile(
        id: 'labels',
        name: 'Counter TSC',
        kind: PrinterKind.label,
        host: '10.0.0.1',
      ));
      await registry.upsert(PrinterProfile(
        id: 'till',
        name: 'Till printer',
        kind: PrinterKind.receipt,
        host: '10.0.0.2',
      ));

      // The default is still the first printer added (a label printer), and a
      // receipt job must not be sent to it: TSPL printers print ESC/POS as
      // literal text.
      expect((await registry.defaultPrinter())?.kind, PrinterKind.label);
      expect((await registry.forKind(PrinterKind.receipt))?.id, 'till');
      expect((await registry.forKind(PrinterKind.label))?.id, 'labels');
    });
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
