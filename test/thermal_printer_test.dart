import 'dart:convert';
import 'dart:typed_data';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/printer/printer_service.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/core/utils/formatters.dart';
import 'package:atria/features/pos/pos_screen.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The label printers a shop runs are TSC and Zebra, and the two do not
/// understand each other: a TSPL `BARCODE` command sent to a Zebra prints as
/// literal text on the sticker.
///
/// So the things worth pinning down are (a) that each brand gets its own
/// command language, (b) that the geometry converts correctly for the head that
/// is actually fitted, and (c) that a barcode the target symbology cannot
/// represent is *refused* rather than printed as bars no scanner can read —
/// because the shopkeeper only discovers a bad label at the counter.
void main() {
  const tsc = PrinterProfile(
    id: 'tsc',
    name: 'Counter TSC',
    brand: PrinterBrand.tsc,
    transport: PrinterTransport.network,
    host: '192.168.1.50',
  );

  const zebra = PrinterProfile(
    id: 'zebra',
    name: 'Shelf Zebra',
    brand: PrinterBrand.zebra,
    transport: PrinterTransport.network,
    host: '192.168.1.51',
  );

  const usbZebra = PrinterProfile(
    id: 'zebra-usb',
    name: 'USB Zebra',
    brand: PrinterBrand.zebra,
    transport: PrinterTransport.usb,
    queueName: 'ZDesigner GK420d',
  );

  String text(Uint8List bytes) => latin1.decode(bytes);

  group('printer profile', () {
    test('203 dpi is 8 dots/mm and 300 dpi is 11.8', () {
      // Not `dpi / 25.4`: TSPL defines these two figures itself and interprets
      // `SIZE` with them, so a layout derived from 203/25.4 would be short.
      expect(tsc.dotsPerMm, 8);
      expect(tsc.labelWidthDots, 400); // 50 mm × 8
      expect(tsc.labelHeightDots, 200); // 25 mm × 8

      final finer = tsc.copyWith(dpi: 300);
      expect(finer.dotsPerMm, 11.8);
      expect(finer.labelWidthDots, 590); // 50 mm × 11.8
      expect(finer.labelHeightDots, 295);
    });

    test('a hand-edited settings row is clamped, not rejected', () {
      // A printer configured with an impossible value must still open in
      // Settings — refusing to load it would leave the operator unable to fix
      // it — so the values are pulled back into range instead.
      final profile = PrinterProfile.fromJson({
        'id': 'x',
        'name': 'Odd',
        'brand': 'zebra',
        'transport': 'usb',
        'queueName': 'Q',
        'dpi': 999,
        'darkness': 99,
        'speed': 0,
        'labelWidthMm': 1000,
        'labelHeightMm': 1,
        'gapMm': 50,
        'copies': 999,
        'port': 999999,
      });
      expect(profile.brand, PrinterBrand.zebra);
      expect(profile.transport, PrinterTransport.usb);
      // 999 dpi is not a head Apex Books can lay out for, so it falls back to 203
      // rather than silently mis-scaling every coordinate.
      expect(profile.dpi, 203);
      expect(profile.darkness, 15);
      expect(profile.speed, 1);
      expect(profile.labelWidthMm, 220);
      expect(profile.labelHeightMm, 5);
      expect(profile.gapMm, 10);
      expect(profile.copies, 50);
      expect(profile.port, 65535);
    });

    test('survives a round-trip through settings', () {
      final restored =
          PrinterProfile.parseList(PrinterProfile.encodeList([tsc, usbZebra]));
      expect(restored, hasLength(2));
      expect(restored[0].brand, PrinterBrand.tsc);
      expect(restored[0].host, '192.168.1.50');
      expect(restored[1].transport, PrinterTransport.usb);
      expect(restored[1].queueName, 'ZDesigner GK420d');
    });

    test('a corrupt settings blob reads as no printers', () {
      // Not an exception: a pref that cannot be parsed must not make the
      // Settings screen unopenable.
      expect(PrinterProfile.parseList('{ not json'), isEmpty);
      expect(PrinterProfile.parseList(null), isEmpty);
      expect(PrinterProfile.parseList('[]'), isEmpty);
    });

    test('knows when it cannot be sent to', () {
      expect(tsc.isUsable, isTrue);
      expect(tsc.problem, isNull);

      final noHost = tsc.copyWith(host: '  ');
      expect(noHost.isUsable, isFalse);
      expect(noHost.problem, 'No printer address was set.');

      final noQueue = usbZebra.copyWith(queueName: '');
      expect(noQueue.isUsable, isFalse);
      expect(noQueue.problem, 'No installed printer was chosen.');
    });
  });

  group('barcodes', () {
    test('EAN-13 check digit matches a known-good code', () {
      expect(LabelEncoder.ean13CheckDigit('590123412345'), '7');
      expect(LabelEncoder.isValidEan13('5901234123457'), isTrue);
      expect(LabelEncoder.isValidEan13('5901234123456'), isFalse);
      expect(LabelEncoder.isValidEan13('590123412345'), isFalse);
    });

    test('EAN-13 is sent without its check digit', () {
      // Both TSPL and ZPL compute the last digit themselves; sending all 13
      // makes printers either reject the command or print a 14th bar.
      expect(
        LabelEncoder.resolveBarcode('5901234123457', BarcodeSymbology.ean13),
        '590123412345',
      );
    });

    test('a wrong EAN-13 check digit is refused, not printed', () {
      expect(
        () => LabelEncoder.resolveBarcode(
          '5901234123456',
          BarcodeSymbology.ean13,
        ),
        throwsA(
          isA<LabelException>().having(
            (error) => error.message,
            'message',
            contains('check digit is wrong'),
          ),
        ),
      );
    });

    test('each symbology refuses what it cannot encode', () {
      expect(
        () => LabelEncoder.resolveBarcode('12345', BarcodeSymbology.ean13),
        throwsA(isA<LabelException>()),
      );
      // Code 39 is uppercase-only, so it is upper-cased rather than refused.
      expect(
        LabelEncoder.resolveBarcode('abc-123', BarcodeSymbology.code39),
        'ABC-123',
      );
      expect(
        () => LabelEncoder.resolveBarcode('abc_123', BarcodeSymbology.code39),
        throwsA(isA<LabelException>()),
      );
      // Code 128 is printable ASCII only, so the rupee sign is not encodable.
      expect(
        LabelEncoder.resolveBarcode('ATRIA-1', BarcodeSymbology.code128),
        'ATRIA-1',
      );
      expect(
        () => LabelEncoder.resolveBarcode('caf\u00e9', BarcodeSymbology.code128),
        throwsA(isA<LabelException>()),
      );
    });

    test('an item with no barcode uses its code, and the data picks the symbology',
        () {
      final item = _item(barcode: null, sku: 'SKU-9');
      expect(ThermalPrinterService.barcodeForItem(item), 'SKU-9');

      final noSku = _item(barcode: null, sku: null);
      expect(ThermalPrinterService.barcodeForItem(noSku), noSku.id.toUpperCase());

      expect(
        ThermalPrinterService.symbologyFor('5901234123457'),
        BarcodeSymbology.ean13,
      );
      // A 13-digit number with a bad check digit is not an EAN, so it prints as
      // Code 128 instead of failing.
      expect(
        ThermalPrinterService.symbologyFor('5901234123456'),
        BarcodeSymbology.code128,
      );
      expect(
        ThermalPrinterService.symbologyFor('INV-2026-001'),
        BarcodeSymbology.code128,
      );
    });
  });

  group('TSPL (TSC)', () {
    final encoder = TsplEncoder(tsc);

    test('emits the label size in millimetres and a PRINT for the copies', () {
      final bytes = encoder.encode(
        const LabelDocument(
          title: 'Canon NPG90 Toner',
          barcode: 'INV-2026-001',
          symbology: BarcodeSymbology.code128,
          priceLine: 'Rs 1,180.00',
          copies: 2,
        ),
      );
      final output = text(bytes);
      expect(output, contains('SIZE 50 mm,25 mm'));
      expect(output, contains('GAP 2 mm,0 mm'));
      expect(output, contains('DIRECTION 1'));
      expect(output, contains('DENSITY 8'));
      expect(output, contains('SPEED 4'));
      expect(output, contains('CLS'));
      expect(output, contains('"128",'));
      expect(output, contains('"INV-2026-001"'));
      // TSPL counts copies per set, so this is one set of two.
      expect(output, contains('PRINT 1,2'));
      expect(output, endsWith('\r\n'));
    });

    test('a 300 dpi head magnifies against the same millimetre label', () {
      final coarse = text(encoder.encodeTestLabel());
      final fine = text(TsplEncoder(tsc.copyWith(dpi: 300)).encodeTestLabel());
      expect(coarse, contains('TEXT '));
      expect(fine, contains('TEXT '));
      // The finer head uses the smaller built-in font, because the same dot
      // count is a physically bigger glyph.
      expect(coarse, contains('"3",'));
      expect(fine, contains('"2",'));
    });

    test('folds characters that would break a TSPL string literal', () {
      // A quote or a backslash inside a TSPL string literal ends it early and
      // the rest of the label is printed as commands. Folding to lookalikes
      // keeps `3" PVC` reading as `3" PVC` rather than as a typo.
      expect(encoder.printable('3" PVC \\ pipe'), "3' PVC / pipe");
    });

    test('is single-byte, so a non-ASCII cursor cannot desynchronise it', () {
      final bytes = TsplEncoder(tsc).encode(
        const LabelDocument(
          title: 'Caf\u00e9 Toner',
          barcode: 'INV-1',
          symbology: BarcodeSymbology.code128,
        ),
      );
      // Every byte is ASCII: latin1 decoding is lossless, so no multi-byte
      // sequence can be read by the printer as two junk glyphs.
      expect(bytes.every((byte) => byte < 128), isTrue);
    });
  });

  group('ZPL (Zebra)', () {
    final encoder = ZplEncoder(zebra);

    test('wraps the field set in ^XA/^XZ with the label geometry', () {
      final output = text(
        encoder.encode(
          const LabelDocument(
            title: 'Canon NPG90 Toner',
            barcode: '5901234123457',
            symbology: BarcodeSymbology.ean13,
            priceLine: 'Rs 1,180.00',
            copies: 3,
          ),
        ),
      );
      expect(output, startsWith('^XA'));
      expect(output, endsWith('^XZ'));
      expect(output, contains('^PW400'));
      expect(output, contains('^LL200'));
      expect(output, contains('^CI28'));
      // Die-cut stock is gap-sensed; `^MNN` (continuous) here would make the
      // printer feed a whole label between labels.
      expect(output, contains('^MNY'));
      // TSPL DENSITY is 0-15 and ZPL ~SD is 0-30, so 8 becomes 16.
      expect(output, contains('~SD16'));
      expect(output, contains('^PQ3'));
      // EAN-13 without the check digit the printer computes itself.
      expect(output, contains('^BE'));
      expect(output, contains('^FD590123412345^FS'));
    });

    test('uses the brand its own barcode command', () {
      final code39 = text(
        encoder.encode(
          const LabelDocument(
            title: 'Bolt',
            barcode: 'ABC-123',
            symbology: BarcodeSymbology.code39,
          ),
        ),
      );
      expect(code39, contains('^B3'));
      expect(code39, isNot(contains('^BC')));
    });

    test('drops the ZPL control characters from a field', () {
      final output = text(
        encoder.encode(
          const LabelDocument(
            title: 'Gear ^XZ hax',
            barcode: 'A-1',
            symbology: BarcodeSymbology.code128,
          ),
        ),
      );
      // A literal `^XZ` inside a field would end the job and print the rest of
      // the label as commands.
      expect(output, isNot(contains('^FDGear ^XZ')));
      // The caret is folded to a space, and the run of spaces is collapsed.
      expect(output, contains('^FDGear XZ hax^FS'));
    });

    test('continuous stock is told there is no gap', () {
      final output = text(
        ZplEncoder(zebra.copyWith(gapMm: 0)).encodeTestLabel(),
      );
      expect(output, contains('^MNN'));
    });
  });

  group('money and job assembly', () {
    test('the rupee glyph is spelled out, because no built-in font has it', () {
      expect(LabelEncoder.money('\u20b91,180.00'), 'Rs1,180.00');
      expect(LabelEncoder.money('Rs. 1,180.50'), 'Rs 1,180.50');
      expect(LabelEncoder.money(null), '');
    });

    test('a label carrying the rupee glyph sends none of it', () {
      final bytes = ZplEncoder(zebra).encode(
        const LabelDocument(
          title: 'Toner',
          barcode: 'A-1',
          symbology: BarcodeSymbology.code128,
          priceLine: '\u20b91,180.00',
        ),
      );
      final output = latin1.decode(bytes);
      expect(output, contains('^FDRs1,180.00^FS'));
      expect(bytes.any((byte) => byte >= 128), isFalse);
    });

    test('one job carries every label in it', () {
      final encoder = TsplEncoder(tsc);
      final job = text(
        encoder.encodeAll([
          const LabelDocument(
            title: 'A',
            barcode: 'A-1',
            symbology: BarcodeSymbology.code128,
          ),
          const LabelDocument(
            title: 'B',
            barcode: 'B-1',
            symbology: BarcodeSymbology.code128,
          ),
        ]),
      );
      expect('PRINT 1,1'.allMatches(job).length, 2);
    });

    test('an empty job is refused rather than sent as nothing', () {
      expect(() => TsplEncoder(tsc).encodeAll(const []),
          throwsA(isA<LabelException>()));
    });
  });

  group('catalog labels', () {
    test('one sticker per unit, and a single sticker for loose stock', () {
      final item = _item();
      // Whole numbers repeat; a fraction cannot be stuck to a half sticker, so
      // it prints once rather than rounding into the wrong stock count.
      expect(
        ThermalPrinterService.labelForSaleLine(item, quantity: 3).copies,
        3,
      );
      expect(
        ThermalPrinterService.labelForSaleLine(item, quantity: 0.5).copies,
        1,
      );
      expect(
        ThermalPrinterService.labelForSaleLine(item, quantity: 1).copies,
        1,
      );
      // A runaway run is capped instead of emptying the roll.
      expect(
        ThermalPrinterService.labelForSaleLine(item, quantity: 500).copies,
        50,
      );
    });

    test('the MRP line only appears when it differs from the price', () {
      final discounted = ThermalPrinterService.labelForItem(
        _item(salePrice: 100, mrp: 150),
      );
      expect(discounted.strikethroughLine, contains('MRP'));
      expect(discounted.strikethroughLine, contains('150'));
      expect(discounted.priceLine, contains('100'));

      // Printing the same number twice looks like a mistake, so it is dropped.
      expect(
        ThermalPrinterService.labelForItem(
          _item(salePrice: 100, mrp: 100),
        ).strikethroughLine,
        isNull,
      );
      expect(
        ThermalPrinterService.labelForItem(_item(salePrice: 100, mrp: null))
            .strikethroughLine,
        isNull,
      );
    });

    test('the second line is the identifier the shop actually uses', () {
      expect(
        ThermalPrinterService.labelForItem(_item(sku: 'SKU-1')).subtitle,
        'SKU-1',
      );
      expect(
        ThermalPrinterService.labelForItem(_item(sku: null, hsn: '84439959'))
            .subtitle,
        'HSN 84439959',
      );
      expect(
        ThermalPrinterService.labelForItem(_item(sku: null, hsn: null)).subtitle,
        isNull,
      );
    });

    test('the whole label fits inside the sticker', () {
      // A layout that draws past the label height is clipped by the printer,
      // which reads as a hardware fault rather than a too-small label.
      final encoder = TsplEncoder(tsc);
      final output = text(
        encoder.encode(
          ThermalPrinterService.labelForItem(
            _item(name: 'DELL 18.5 INCH MONITOR', salePrice: 6850, mrp: 8999),
            footer: 'Active IT Solutions',
          ),
        ),
      );
      final nameScale = RegExp(r'TEXT \d+,(\d+),"\d",0,(\d),').firstMatch(output);
      expect(nameScale, isNotNull);
      expect(int.parse(nameScale!.group(1)!), lessThan(tsc.labelHeightDots));
    });
  });

  /// The counter screen's whole reason to exist is speed, and the way to make a
  /// till fast is to make it a *cart in front of the ordinary billing engine*
  /// rather than a second, quicker, slightly-different implementation of GST.
  ///
  /// That claim is only worth anything if it is checked: a counter sale has to
  /// produce the same invoice the sales editor would, with the same tax split
  /// and the same rounded total, or the shop quietly has two sets of books.
  group('counter sale', () {
    const timeout = Timeout(Duration(minutes: 2));

    Future<(AppDatabase, ProviderContainer, String)> boot() async {
      final db = AppDatabase.test(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      final firm = await db.firmRepository.create(name: 'Apex Integrations');
      await container.read(activeFirmIdProvider.notifier).select(firm.id);
      return (db, container, firm.id);
    }

    Future<void> teardown(
      WidgetTester tester,
      AppDatabase db,
      ProviderContainer container,
    ) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await db.close();
    }

    Future<void> pumpPos(WidgetTester tester, ProviderContainer container) =>
        tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const PosScreen(),
            ),
          ),
        );

    /// Scans a code the way a wedge scanner does: it types and presses enter.
    Future<void> scan(WidgetTester tester, String code) async {
      await tester.enterText(find.byType(TextField).first, code);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('a scanned item bills through the same engine as an invoice',
        (tester) async {
      final (db, container, firmId) = await boot();
      await db.itemRepositoryFor(firmId).create(
            name: 'Canon NPG90 Toner',
            sku: 'SKU-1',
            barcode: '8901234567890',
            salePrice: 1000,
            gstRate: 18,
            openingStock: 5,
          );

      tester.view.physicalSize = const Size(1300, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpPos(tester, container);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Counter sale'), findsOneWidget);

      await scan(tester, '8901234567890');

      // Walk-in buyer in the firm's own state: 18% on 1000 becomes CGST 90 +
      // SGST 90, and the total the pane shows is the engine's, not the cart's
      // own arithmetic.
      expect(find.text('Canon NPG90 Toner'), findsWidgets);
      expect(tester.takeException(), isNull);
      expect(
        find.text(Formatters.money(Decimal.fromInt(1180))),
        findsWidgets,
        reason: 'the cart must show the tax-inclusive total, not the rate',
      );

      await tester.tap(find.text('Complete sale'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);

      final sales = db.salesRepositoryFor(firmId);
      final saved = await sales.list();
      expect(saved, hasLength(1));
      expect(saved.single.docType, 'invoice');
      expect(saved.single.grandTotal, closeTo(1180, 0.01));
      expect(saved.single.taxableValue, closeTo(1000, 0.01));
      expect(saved.single.cgst, closeTo(90, 0.01));
      expect(saved.single.sgst, closeTo(90, 0.01));
      expect(saved.single.igst, closeTo(0, 0.01),
          reason: 'a walk-in sale in the firm\'s own state is not inter-state');
      expect(saved.single.isInterState, isFalse);

      // "Taken in full" is the default, so the money is booked in the same
      // motion as the bill rather than left as a receivable to chase.
      expect(saved.single.paidAmount, closeTo(1180, 0.01));
      expect(saved.single.balanceDue, closeTo(0, 0.01));

      final payments = await db.paymentRepositoryFor(firmId).list();
      expect(payments, hasLength(1));
      expect(payments.single.amount, closeTo(1180, 0.01));
      expect(payments.single.type, 'payment_in');

      // And the cart is empty afterwards, so the next customer starts clean.
      expect(find.text('Cart'), findsWidgets);
      expect(find.text('Complete sale'), findsOneWidget);

      await teardown(tester, db, container);
    }, timeout: timeout);

    testWidgets('an unknown code says so instead of adding a blank line',
        (tester) async {
      final (db, container, firmId) = await boot();
      await db.itemRepositoryFor(firmId).create(
            name: 'Canon NPG90 Toner',
            salePrice: 1000,
            gstRate: 18,
          );

      tester.view.physicalSize = const Size(1300, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpPos(tester, container);
      await tester.pump(const Duration(milliseconds: 300));

      await scan(tester, '0000000000000');

      expect(tester.takeException(), isNull);
      expect(find.textContaining('No item matches'), findsOneWidget);

      // The till must refuse to complete an empty sale rather than writing a
      // zero-rupee invoice into the books.
      await tester.tap(find.text('Complete sale'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(await db.salesRepositoryFor(firmId).list(), isEmpty);

      await teardown(tester, db, container);
    }, timeout: timeout);
  });
}

/// A catalogue item with everything a label needs.
ItemEntity _item({
  String name = 'Canon NPG90 Toner',
  String? sku = 'SKU-1',
  String? hsn = '84439959',
  String? barcode = 'INV-2026-001',
  double salePrice = 1180,
  double? mrp,
  String unit = 'pcs',
  String stockType = 'tracked',
}) =>
    ItemEntity(
      id: 'itm_01H',
      firmId: 'firm_1',
      name: name,
      sku: sku,
      hsn: hsn,
      unit: unit,
      costingMethod: 'moving_average',
      salePrice: salePrice,
      purchasePrice: 900,
      mrp: mrp,
      gstRate: 18,
      cessRate: 0,
      taxMode: 'exclusive',
      isService: false,
      stockType: stockType,
      openingStock: 0,
      currentStock: 12,
      lowStockAlert: 0,
      barcode: barcode,
      isDeleted: false,
      createdAt: _epoch,
      updatedAt: _epoch,
    );

/// A fixed timestamp, so the fixture does not depend on when the test ran.
final DateTime _epoch = DateTime.utc(2026, 1, 1);
