import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/services/invoice_pdf.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/rendered_text.dart';

/// What a printed invoice says about money.
///
/// Three failures hide here, and every one of them is invisible until someone
/// is standing at the counter with the PDF in front of them:
///
/// - The QR encoded the grand total. On a part-paid bill it asked the customer
///   for the full amount again.
/// - A settled invoice still printed bank details and a "scan to pay" — a
///   payment instruction on a document that is already paid.
/// - Neither figure that answers "has this been paid?" was on the page at all.
///
/// Assertions are on the text decoded out of the PDF's own content streams.
/// The QR is the exception: it is a raster, so the amount it encodes is
/// asserted through [InvoicePdf.collectableAmount], which is the decision that
/// feeds it.
void main() {
  late AppDatabase db;
  final opened = <AppDatabase>[];

  AppDatabase openMemory() {
    final d = AppDatabase.test(NativeDatabase.memory());
    opened.add(d);
    return d;
  }

  setUp(() {
    db = openMemory();
  });

  tearDown(() async {
    for (final d in opened) {
      await d.close();
    }
    opened.clear();
  });

  Future<FirmEntity> seedFirm({bool withUpi = true}) async {
    await db.into(db.firms).insert(
          FirmsCompanion.insert(
            id: 'f1',
            name: 'Alpha Traders',
            gstin: const Value('29ABCDE1234F1Z5'),
            upiId: Value(withUpi ? 'alpha@upi' : null),
            showQrOnInvoice: Value(withUpi),
            showBankOnInvoice: const Value(true),
            bankName: const Value('HDFC Bank'),
            bankAccountNumber: const Value('50100234567890'),
          ),
        );
    return (db.select(db.firms)..where((f) => f.id.equals('f1'))).getSingle();
  }

  Future<SalesInvoiceEntity> seedInvoice(
    FirmEntity firm, {
    String id = 'inv-1',
    String docType = 'invoice',
    double grandTotal = 5000,
    double paidAmount = 0,
    double balanceDue = 5000,
    String status = 'confirmed',
    String paymentStatus = 'unpaid',
  }) async {
    final invoice = await db.into(db.salesInvoices).insertReturning(
          SalesInvoicesCompanion.insert(
            id: id,
            firmId: firm.id,
            number: 'INV-${id.split('-').last}',
            docType: Value(docType),
            invoiceDate: DateTime(2026, 4, 1),
            partyName: const Value('Beti Foods'),
            status: Value(status),
            paymentStatus: Value(paymentStatus),
            grandTotal: Value(grandTotal),
            paidAmount: Value(paidAmount),
            balanceDue: Value(balanceDue),
          ),
        );
    await db.into(db.salesInvoiceItems).insert(
          SalesInvoiceItemsCompanion.insert(
            id: 'item-$id',
            invoiceId: invoice.id,
            name: 'Masala Chai',
            quantity: 2,
            rate: grandTotal / 2,
            gstRate: const Value(18),
            total: Value(grandTotal),
          ),
        );
    return invoice;
  }

  group('the collect-request QR', () {
    test('asks for the balance, not the grand total', () async {
      final firm = await seedFirm();
      final invoice = await seedInvoice(
        firm,
        grandTotal: 5000,
        paidAmount: 3000,
        balanceDue: 2000,
        paymentStatus: 'partial',
      );

      expect(InvoicePdf.forFirm(firm).collectableAmount(invoice), '2000.00');
    });

    test('asks for the whole value on an untouched invoice', () async {
      final firm = await seedFirm();
      final invoice = await seedInvoice(firm);

      expect(InvoicePdf.forFirm(firm).collectableAmount(invoice), '5000.00');
    });

    test('disappears once nothing is outstanding', () async {
      final firm = await seedFirm();
      final invoice = await seedInvoice(
        firm,
        paidAmount: 5000,
        balanceDue: 0,
        paymentStatus: 'paid',
      );

      expect(InvoicePdf.forFirm(firm).collectableAmount(invoice), isNull);
    });

    test('is absent from a quotation, which is not yet payable', () async {
      final firm = await seedFirm();
      // A quotation is stored with a zero balance, so `balanceDue > 0` would
      // already exclude it — the assertion is that the doc-type gate is what
      // excludes it, by giving the quotation a live balance it should ignore.
      final invoice = await seedInvoice(
        firm,
        docType: 'quotation',
        balanceDue: 5000,
      );

      expect(InvoicePdf.forFirm(firm).collectableAmount(invoice), isNull);
    });

    test('a settled invoice prints no bank details either', () async {
      final firm = await seedFirm();
      final settled = await seedInvoice(
        firm,
        paidAmount: 5000,
        balanceDue: 0,
        paymentStatus: 'paid',
      );
      final unpaid = await seedInvoice(firm, id: 'inv-2');

      final paidText = await renderedText(await InvoicePdf.forFirm(firm)
          .build(invoice: settled, items: await _items(db, settled.id)));
      final unpaidText = await renderedText(await InvoicePdf.forFirm(firm)
          .build(invoice: unpaid, items: await _items(db, unpaid.id)));

      expect(unpaidText, contains('HDFC Bank'),
          reason: 'an unpaid invoice is where payment instructions belong');
      expect(paidText, isNot(contains('HDFC Bank')),
          reason: 'a paid invoice asking for a transfer is a document that '
              'invites the customer to pay twice');
    });
  });

  group('the totals block', () {
    test('a part-paid invoice prints both figures', () async {
      final firm = await seedFirm();
      final invoice = await seedInvoice(
        firm,
        grandTotal: 5000,
        paidAmount: 3000,
        balanceDue: 2000,
        paymentStatus: 'partial',
      );
      final text = await renderedText(await InvoicePdf.forFirm(firm)
          .build(invoice: invoice, items: await _items(db, invoice.id)));

      expect(text, contains('GRAND TOTAL'));
      expect(text, contains('Amount Paid'));
      expect(text, contains('3,000.00'));
      expect(text, contains('Balance Due'));
      expect(text, contains('2,000.00'));
    });

    test('an untouched invoice prints the balance but not a zero paid', () async {
      // "Balance Due ₹5,000" restating the grand total is the line the customer
      // is looking for and is worth printing. "Amount Paid ₹0.00" is noise
      // dressed as information, so it stays off.
      final firm = await seedFirm();
      final invoice = await seedInvoice(firm);
      final text = await renderedText(await InvoicePdf.forFirm(firm)
          .build(invoice: invoice, items: await _items(db, invoice.id)));

      expect(text, contains('Balance Due'));
      expect(text, isNot(contains('Amount Paid')));
    });

    test('a quotation prints neither, even with a live balance', () async {
      // Quotations, orders and delivery notes are all stored with
      // DocumentSettlement.settled — a zero balance and a 'paid' status —
      // because the bill raised against them is the payable one.
      final firm = await seedFirm();
      final invoice = await seedInvoice(
        firm,
        docType: 'sales_order',
        balanceDue: 5000,
      );
      final text = await renderedText(await InvoicePdf.forFirm(firm)
          .build(invoice: invoice, items: await _items(db, invoice.id)));

      expect(text, contains('5,000.00'));
      expect(text, isNot(contains('Balance Due')));
    });
  });

  group('the header stamp', () {
    test('a settled invoice is stamped PAID IN FULL', () async {
      final firm = await seedFirm();
      final invoice = await seedInvoice(
        firm,
        paidAmount: 5000,
        balanceDue: 0,
        paymentStatus: 'paid',
      );
      final text = await renderedText(await InvoicePdf.forFirm(firm)
          .build(invoice: invoice, items: await _items(db, invoice.id)));

      expect(text, contains('PAID IN FULL'));
    });

    test('a part-paid invoice is not stamped', () async {
      final firm = await seedFirm();
      final invoice = await seedInvoice(
        firm,
        paidAmount: 3000,
        balanceDue: 2000,
        paymentStatus: 'partial',
      );
      final text = await renderedText(await InvoicePdf.forFirm(firm)
          .build(invoice: invoice, items: await _items(db, invoice.id)));

      expect(text, isNot(contains('PAID IN FULL')));
    });

    test('a nil-value invoice is not stamped paid', () async {
      // It balances itself without anyone sending money. Calling that PAID IN
      // FULL would be a claim about a document nobody paid.
      final firm = await seedFirm();
      final invoice = await seedInvoice(
        firm,
        grandTotal: 0,
        paidAmount: 0,
        balanceDue: 0,
      );
      final text = await renderedText(await InvoicePdf.forFirm(firm)
          .build(invoice: invoice, items: await _items(db, invoice.id)));

      expect(text, isNot(contains('PAID IN FULL')));
    });

    test('a cancelled invoice says CANCELLED, not paid', () async {
      // The cancel path zeroes the balance so ageing stops counting it. That
      // is bookkeeping, not settlement.
      final firm = await seedFirm();
      final invoice = await seedInvoice(
        firm,
        paidAmount: 5000,
        balanceDue: 0,
        paymentStatus: 'paid',
        status: 'cancelled',
      );
      final text = await renderedText(await InvoicePdf.forFirm(firm)
          .build(invoice: invoice, items: await _items(db, invoice.id)));

      expect(text, contains('CANCELLED'));
      expect(text, isNot(contains('PAID IN FULL')));
      expect(text, isNot(contains('Amount Paid')),
          reason: 'a zeroed balance beside a paid amount is the exact '
              'confusion the stamp exists to settle');
    });
  });
}

Future<List<SalesInvoiceItemEntity>> _items(AppDatabase db, String id) =>
    (db.select(db.salesInvoiceItems)
          ..where((i) => i.invoiceId.equals(id)))
        .get();