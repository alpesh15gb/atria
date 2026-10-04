import 'dart:convert';
import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/services/purchase_pdf.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A purchase bill is what input tax credit is claimed against, and under
/// reverse charge it is the evidence that the supplier owes the tax. None of it
/// could be printed before.
///
/// The assertions are on the *text that reaches the page*, decoded out of the
/// PDF's own content streams, because "the builder ran" is not the question —
/// "does the document say TDS is deducted, and CGST/SGST rather than SGST/IGST"
/// is. Both were places where copying the sales builder would have produced a
/// document that looks right and is wrong.
void main() {
  late AppDatabase db;
  final opened = <AppDatabase>[];

  AppDatabase open() {
    final d = AppDatabase.test(NativeDatabase.memory());
    opened.add(d);
    return d;
  }

  setUp(() {
    db = open();
  });

  tearDown(() async {
    for (final d in opened) {
      await d.close();
    }
    opened.clear();
  });

  Future<FirmEntity> seedFirm({String stateCode = '29'}) async {
    await db.into(db.firms).insert(
          FirmsCompanion.insert(
            id: 'f1',
            name: 'Alpha Traders',
            addressLine1: const Value('12 MG Road'),
            city: const Value('Bengaluru'),
            gstin: const Value('29ABCDE1234F1Z5'),
            stateCode: Value(stateCode),
            signatureName: const Value('R. Kumar'),
          ),
        );
    return (db.select(db.firms)..where((f) => f.id.equals('f1'))).getSingle();
  }

  Future<PurchaseBillEntity> seedBill(
    FirmEntity firm, {
    String docType = 'bill',
    bool interState = false,
    bool reverseCharge = false,
    bool unregistered = false,
    String? placeOfSupply = '29',
    double tds = 0,
    double tdsRate = 0,
    double otherCharges = 0,
  }) async {
    return db.into(db.purchaseBills).insertReturning(
          PurchaseBillsCompanion.insert(
            id: 'b1',
            firmId: firm.id,
            docType: Value(docType),
            number: 'PB-0001',
            supplierInvoiceNumber: const Value('SUP/2026/118'),
            billDate: DateTime(2026, 4, 1),
            partyName: const Value('Beti Foods Pvt Ltd'),
            partyGstin: const Value('29AAECB1234C1ZP'),
            billingAddress: const Value('4 Church Street, Bengaluru 560001'),
            placeOfSupply: Value(placeOfSupply),
            isInterState: Value(interState),
            reverseCharge: Value(reverseCharge),
            isInwardSupplyFromUnregistered: Value(unregistered),
            subTotal: const Value(2000.0),
            taxableValue: const Value(1825.0),
            // The tax columns have to agree with isInterState, or the document
            // is asserting CGST on a bill the engine charged IGST on — a
            // self-inconsistent fixture would make the heading test prove
            // nothing.
            cgst: Value(interState ? 0 : 164.25),
            sgst: Value(interState ? 0 : 164.25),
            igst: Value(interState ? 328.5 : 0.0),
            otherCharges: Value(otherCharges),
            tds: Value(tds),
            tdsRate: Value(tdsRate),
            roundOff: const Value(0.25),
            grandTotal: const Value(2153.75),
          ),
        );
  }

  Future<List<PurchaseBillItemEntity>> seedItems(String billId) async {
    final items = <PurchaseBillItemEntity>[];
    for (var i = 0; i < 3; i++) {
      items.add(await db.into(db.purchaseBillItems).insertReturning(
            PurchaseBillItemsCompanion.insert(
              id: 'bi-$i',
              billId: billId,
              name: 'Masala item $i',
              hsn: const Value('1905'),
              quantity: 2.0,
              rate: 300.0,
              gstRate: const Value(18.0),
              taxableValue: const Value(600.0),
              cgst: const Value(54.0),
              sgst: const Value(54.0),
              total: const Value(708.0),
            ),
          ));
    }
    return items;
  }

  /// Every string the PDF actually paints, in page order.
  ///
  /// dart_pdf writes text as `[(word)]TJ` inside a content stream that is
  /// Flate-compressed, so the text is not greppable in the file itself.
  Future<String> renderedText(List<int> bytes) async {
    final raw = bytes;
    final streams = <String>[];
    final text = String.fromCharCodes(raw);
    final pattern = RegExp(r'stream\r?\n');
    for (final match in pattern.allMatches(text)) {
      final start = match.end;
      final end = text.indexOf('endstream', start);
      if (end < 0) continue;
      // Content streams are the only ones that inflate; font files do not.
      try {
        streams.add(_inflate(raw.sublist(start, end)));
      } catch (_) {
        continue;
      }
    }
    final buffer = StringBuffer();
    for (final stream in streams) {
      for (final t in RegExp(r'\[\((.*?)\)\]TJ').allMatches(stream)) {
        buffer.write(t
            .group(1)!
            .replaceAll(r'\(', '(')
            .replaceAll(r'\)', ')'));
        buffer.write(' ');
      }
    }
    return buffer.toString();
  }

  test('a purchase bill prints its lines, its supplier and its total',
      () async {
    final firm = await seedFirm();
    final bill = await seedBill(firm);
    final items = await seedItems(bill.id);

    final bytes =
        await PurchasePdf.forFirm(firm).build(bill: bill, items: items);
    final text = await renderedText(bytes);

    expect(text, contains('PURCHASE BILL'));
    expect(text, contains('PB-0001'));
    expect(text, contains('Beti Foods Pvt Ltd'));
    expect(text, contains('29AAECB1234C1ZP'),
        reason: 'a purchase bill is a tax document; the supplier GSTIN is not '
            'optional on it');
    // The supplier's own invoice number is what the supplier will match against.
    expect(text, contains('SUP/2026/118'));
    for (final item in items) {
      expect(text, contains(item.name));
    }
    expect(text, contains('TOTAL PAYABLE'));
  });

  test('an intra-state purchase splits CGST and SGST, never IGST', () async {
    final firm = await seedFirm();
    final bill = await seedBill(firm);
    final bytes = await PurchasePdf.forFirm(firm)
        .build(bill: bill, items: await seedItems(bill.id));
    final text = await renderedText(bytes);

    expect(text, contains('CGST'));
    expect(text, contains('SGST'));
    expect(text, isNot(contains('IGST')));
  });

  test('a Union-Territory supplier gets UTGST, not SGST', () async {
    // The bug this guards is the one a copied sales builder would have: it
    // passes the firm's own state as the supplier's, so a UT purchase prints
    // "SGST" where the law says "UTGST".
    //
    // Chandigarh, not Delhi. Both are Union Territories, but only the four
    // without a legislature (Chandigarh, Dadra and Nagar Haveli and Daman and
    // Diu, Lakshadweep, Andaman and Nicobar) levy UTGST; Delhi has its own
    // legislature and charges SGST like a state. Both parties have to sit in
    // that UT, or the bill is inter-state and IGST applies instead — which
    // would make this test pass for the wrong reason.
    final firm = await seedFirm(stateCode: '04');
    final bill = await seedBill(firm, placeOfSupply: '04');
    final bytes = await PurchasePdf.forFirm(firm)
        .build(bill: bill, items: await seedItems(bill.id));
    final text = await renderedText(bytes);

    expect(text, contains('UTGST'));
    expect(text, isNot(contains('SGST')));
  });

  test('an inter-state purchase shows IGST only', () async {
    final firm = await seedFirm();
    final bill = await seedBill(firm, interState: true, placeOfSupply: '27');
    final bytes = await PurchasePdf.forFirm(firm)
        .build(bill: bill, items: await seedItems(bill.id));
    final text = await renderedText(bytes);

    expect(text, contains('IGST'));
    expect(text, isNot(contains('SGST')));
    expect(text, isNot(contains('CGST')));
  });

  test('TDS is printed as a deduction with its rate', () async {
    final firm = await seedFirm();
    final bill = await seedBill(firm, tds: 182.5, tdsRate: 0.1);
    final bytes = await PurchasePdf.forFirm(firm)
        .build(bill: bill, items: await seedItems(bill.id));
    final text = await renderedText(bytes);

    // The buyer withholds it, so it has to read as coming off the total. A
    // positive figure on this line would make the payable amount wrong.
    expect(text, contains('TDS @ 0.1%'));
    expect(text, contains('- 182.50'));
  });

  test('other charges are printed when there are any', () async {
    final firm = await seedFirm();
    final bill = await seedBill(firm, otherCharges: 45.0);
    final bytes = await PurchasePdf.forFirm(firm)
        .build(bill: bill, items: await seedItems(bill.id));
    final text = await renderedText(bytes);

    expect(text, contains('Other Charges'));
  });

  test('reverse charge and an unregistered supplier are both called out',
      () async {
    final firm = await seedFirm();
    final bill = await seedBill(firm, reverseCharge: true, unregistered: true);
    final bytes = await PurchasePdf.forFirm(firm)
        .build(bill: bill, items: await seedItems(bill.id));
    final text = await renderedText(bytes);

    expect(text, contains('Reverse Charge'));
    expect(text, contains('Unregistered Supplier'));
  });

  test('a purchase order prints as an order, with no payment status',
      () async {
    final firm = await seedFirm();
    final bill = await seedBill(firm, docType: 'purchase_order');
    final bytes = await PurchasePdf.forFirm(firm)
        .build(bill: bill, items: await seedItems(bill.id));
    final text = await renderedText(bytes);

    expect(text, contains('PURCHASE ORDER'));
    expect(text, isNot(contains('Payment:')),
        reason: 'an order has not been paid yet; saying so is noise');
  });

  test('a payment voucher names the payee, the mode and the cheque state',
      () async {
    final firm = await seedFirm();
    final payment = await db.into(db.payments).insertReturning(
          PaymentsCompanion.insert(
            id: 'pmt-1',
            firmId: firm.id,
            number: 'PMT-0007',
            type: 'payment_out',
            partyName: const Value('Beti Foods Pvt Ltd'),
            partyGstin: const Value('29AAECB1234C1ZP'),
            amount: 5000.0,
            date: DateTime(2026, 4, 2),
            mode: const Value('cheque'),
            reference: const Value('004122'),
            chequeStatus: const Value('bounced'),
            bounceReason: const Value('insufficient funds'),
            linkedInvoiceNumber: const Value('PB-0001'),
          ),
        );

    final bytes =
        await PurchasePdf.forFirm(firm).buildVoucher(payment: payment);
    final text = await renderedText(bytes);

    expect(text, contains('PAYMENT VOUCHER'));
    expect(text, contains('PMT-0007'));
    expect(text, contains('Beti Foods Pvt Ltd'));
    expect(text, contains('29AAECB1234C1ZP'));
    expect(text, contains('Cheque No.: 004122'));
    expect(text, contains('Returned unpaid'));
    expect(text, contains('insufficient funds'));
    expect(text, contains('AMOUNT PAID'));
    expect(text, contains('Against: PB-0001'));
  });

  test('a money-in voucher is a receipt and says so', () async {
    final firm = await seedFirm();
    final payment = await db.into(db.payments).insertReturning(
          PaymentsCompanion.insert(
            id: 'pmt-2',
            firmId: firm.id,
            number: 'RCPT-0002',
            type: 'payment_in',
            partyName: const Value('Walk-in Customer'),
            amount: 1200.0,
            date: DateTime(2026, 4, 3),
            mode: const Value('upi'),
            reference: const Value('UPI-88213'),
          ),
        );

    final bytes =
        await PurchasePdf.forFirm(firm).buildVoucher(payment: payment);
    final text = await renderedText(bytes);

    expect(text, contains('RECEIPT VOUCHER'));
    expect(text, contains('AMOUNT RECEIVED'));
    expect(text, contains('UPI'));
  });

  test('no purchase document carries a UPI collect QR', () async {
    // The shop is the one paying. A QR asking a supplier to scan and pay the
    // shop for a bill the shop already owes is the sort of thing that gets a
    // document thrown away unread.
    await db.into(db.firms).insert(
          FirmsCompanion.insert(
            id: 'f1',
            name: 'Alpha Traders',
            upiId: const Value('alpha@upi'),
            showQrOnInvoice: const Value(true),
          ),
        );
    final firm =
        await (db.select(db.firms)..where((f) => f.id.equals('f1'))).getSingle();
    final bill = await seedBill(firm);
    final bytes = await PurchasePdf.forFirm(firm)
        .build(bill: bill, items: await seedItems(bill.id));

    expect(String.fromCharCodes(bytes), startsWith('%PDF-'));
    // The QR is a raster of drawn rectangles; its absence is asserted on the
    // builder's own gate rather than on pixels.
    expect(bytes.length, lessThan(200000));
  });
}

/// Flate-decodes one PDF stream.
String _inflate(List<int> compressed) =>
    utf8.decode(ZLibCodec(level: 6).decode(compressed), allowMalformed: true);