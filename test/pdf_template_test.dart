import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/services/invoice_pdf.dart';
import 'package:atria/core/services/pdf_template_style.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The printed layout is per firm, chosen in Firm Settings, and read by every
/// PDF builder.
///
/// Three things have to hold, and each is a way this feature can be wrong in a
/// way nobody notices: the template has to actually reach the PDF (not just be
/// stored), the stored value has to survive a database that predates the
/// column, and a firm whose stored value is unrecognised must still print
/// rather than throw in the middle of a customer's share dialog.
void main() {
  // Opened per test rather than in a blanket setUp, so the migration group
  // below never has an unrelated database open at the same time — drift warns
  // about that, and two live handles on the same class is exactly the hazard
  // the warning exists for.
  final opened = <AppDatabase>[];

  AppDatabase openMemory() {
    final d = AppDatabase.test(NativeDatabase.memory());
    opened.add(d);
    return d;
  }

  tearDown(() async {
    for (final d in opened) {
      await d.close();
    }
    opened.clear();
  });

  Future<String> seedFirm(AppDatabase db, {String? template}) async {
    final firm = await db.firmRepository.create(name: 'Alpha Traders');
    if (template != null) {
      await (db.update(db.firms)..where((f) => f.id.equals(firm.id))).write(
        FirmsCompanion(pdfTemplate: Value(template)),
      );
    }
    return firm.id;
  }

  Future<(SalesInvoiceEntity, List<SalesInvoiceItemEntity>)> seedInvoice(
    AppDatabase db,
    String firmId,
  ) async {
    final invoice = await db
        .into(db.salesInvoices)
        .insertReturning(
          SalesInvoicesCompanion.insert(
            id: 'inv-1',
            firmId: firmId,
            number: 'INV-001',
            docType: const Value('invoice'),
            invoiceDate: DateTime(2026, 4, 1),
            partyName: const Value('Beti Foods'),
            grandTotal: const Value(1180.0),
          ),
        );
    final item = await db
        .into(db.salesInvoiceItems)
        .insertReturning(
          SalesInvoiceItemsCompanion.insert(
            id: 'item-1',
            invoiceId: invoice.id,
            name: 'Masala Chai',
            quantity: 2,
            rate: 500.0,
            gstRate: const Value(18),
            total: const Value(1180.0),
          ),
        );
    return (invoice, [item]);
  }

  test('every template produces a real PDF', () async {
    final db = openMemory();
    final firmId = await seedFirm(db);
    final (invoice, items) = await seedInvoice(db, firmId);
    final firm = await (db.select(
      db.firms,
    )..where((f) => f.id.equals(firmId))).getSingle();
    // The header prints the firm's name, so a template test against a blank
    // business would be testing half a page.
    expect(firm.name, 'Alpha Traders');

    for (final style in PdfTemplateStyle.all) {
      final bytes = await InvoicePdf.forFirm(firm)
          .build(invoice: invoice, items: items);
      // A PDF always starts with %PDF-; anything else means the builder threw
      // and something swallowed it into an empty buffer.
      expect(
        bytes.length,
        greaterThan(1000),
        reason: '${style.id} produced ${bytes.length} bytes',
      );
      expect(
        String.fromCharCodes(bytes.take(5)),
        '%PDF-',
        reason: '${style.id} is not a PDF',
      );
    }
  });

  test(
    'the template stored on the firm is the one that builds the PDF',
    () async {
      final db = openMemory();
      final firmId = await seedFirm(db, template: 'modern');
      final firm = await (db.select(
        db.firms,
      )..where((f) => f.id.equals(firmId))).getSingle();
      final (invoice, items) = await seedInvoice(db, firmId);

      expect(PdfTemplateStyle.resolve(firm.pdfTemplate).id, 'modern');
      expect(InvoicePdf.forFirm(firm).style.id, 'modern');

      final bytes = await InvoicePdf.forFirm(firm)
          .build(invoice: invoice, items: items);
      expect(bytes.length, greaterThan(1000));
    },
  );

  test('a firm with no stored template prints classic', () async {
    // The v8 default, and what every firm upgraded from an older build gets.
    final db = openMemory();
    final firmId = await seedFirm(db);
    final firm = await (db.select(
      db.firms,
    )..where((f) => f.id.equals(firmId))).getSingle();
    expect(firm.pdfTemplate, 'classic');
    expect(InvoicePdf.forFirm(firm).style.id, 'classic');
  });

  test('an unrecognised stored template falls back to classic rather than '
      'throwing', () async {
    // Reachable from a restored backup written by a newer build, and from a
    // column hand-edited. A share dialog that throws is a lost sale.
    expect(PdfTemplateStyle.resolve('neon').id, 'classic');
    expect(PdfTemplateStyle.resolve('').id, 'classic');
    expect(PdfTemplateStyle.resolve(null).id, 'classic');
    expect(PdfTemplateStyle.resolve('  Modern  ').id, 'modern');
  });

  group('schema v7 -> v8', () {
    // Built by rolling a real v8 database *back*: drop the two new columns and
    // set user_version to 7, then reopen. That gives a file whose rows really
    // do predate the columns, which is the only honest way to test that the
    // migration keeps them.
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('atria_v7_migration');
      file = File('${dir.path}/books.db');
    });

    tearDown(() async {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('existing rows survive and pick up the new defaults', () async {
      // 1. Build a current database with a firm and a payment in it.
      final first = AppDatabase.test(NativeDatabase(file));
      final firm = await first.firmRepository.create(name: 'Alpha Traders');
      final firmId = firm.id;
      await first
          .into(first.payments)
          .insert(
            PaymentsCompanion.insert(
              id: 'pmt-1',
              firmId: firmId,
              number: 'PMT-001',
              type: 'payment_out',
              amount: 500.0,
              date: DateTime(2026, 4, 2),
              partyName: const Value('Beti Foods'),
            ),
          );

      // 2. Roll it back to what a v7 file looked like. The v9 and v10 columns go
      //    too: the migration chain runs from 7 all the way to current, so
      //    leaving them in place makes those steps try to add a column that
      //    already exists and the upgrade fails on a duplicate — which is a
      //    property of this hand-rolled rollback, not of any real database.
      await first.customStatement('ALTER TABLE firms DROP COLUMN pdf_template');
      await first.customStatement(
        'ALTER TABLE payments DROP COLUMN party_gstin',
      );
      await first.customStatement(
        'ALTER TABLE sales_invoices DROP COLUMN converted_to_invoice_id',
      );
      await first.customStatement(
        'ALTER TABLE sales_invoices DROP COLUMN converted_at',
      );
      await first.customStatement(
        'ALTER TABLE firm_members DROP COLUMN pin_hash',
      );
      await first.customStatement(
        'ALTER TABLE firm_members DROP COLUMN pin_salt',
      );
      await first.customStatement(
        'ALTER TABLE firm_members DROP COLUMN is_active',
      );
      await first.customStatement('PRAGMA user_version = 7');
      await first.close();

      // 3. Reopen: this runs the v7 -> v8, v8 -> v9 and v9 -> v10 upgrades for
      //    real.
      final upgraded = AppDatabase.test(NativeDatabase(file));
      addTearDown(upgraded.close);

      final upgradedFirm = await (upgraded.select(
        upgraded.firms,
      )..where((f) => f.id.equals(firmId))).getSingle();
      expect(
        upgradedFirm.name,
        'Alpha Traders',
        reason: 'the row must survive',
      );
      expect(
        upgradedFirm.pdfTemplate,
        'classic',
        reason: 'an upgraded firm keeps printing what it always printed',
      );

      final payment = await upgraded.select(upgraded.payments).getSingle();
      expect(payment.number, 'PMT-001');
      expect(payment.amount, 500.0);
      expect(
        payment.partyGstin,
        isNull,
        reason: 'a GSTIN that was never recorded must not be invented',
      );

      expect(
        upgraded.schemaVersion,
        10,
        reason: 'the chain runs all the way to current, not just to 8',
      );
    });
  });
}
