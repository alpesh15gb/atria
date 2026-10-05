import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/item_repository.dart';
import 'package:atria/core/database/repositories/party_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/engine/gst_engine.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_runner.dart';
import 'package:atria/core/reports/gst_return_builder.dart';
import 'package:atria/core/reports/sources/gst/gstr1.dart';
import 'package:atria/core/reports/sources/gst/gstr2a_reconciliation.dart';
import 'package:atria/core/reports/sources/gst/gst_common.dart';
import 'package:atria/core/reports/sources/gst/gstr3b.dart';
import 'package:atria/core/reports/sources/gst/gstr9.dart';
import 'package:atria/core/reports/sources/gst/sac_report.dart';
import 'package:atria/core/reports/sources/gst/sale_summary_by_hsn.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The six GST reports.
///
/// **These assertions are about what gets filed, not about what draws.** Every
/// fixture is chosen so the *wrong* answer is a different number rather than a
/// missing row: a credit note to return goods, a line with no HSN, an
/// unregistered firm, a credit note whose stored tax columns are positive.
///
/// The two properties that matter most and are easiest to get wrong:
///
/// * **The rate is derived, not remembered.** A fixture sells the same item at
///   18% through one invoice and 5% through another, and the HSN summary must
///   produce two rows. Reading the item master's `gstRate` collapses them into
///   one row carrying a taxable value filed against a rate that never applied
///   to all of it, which the portal rejects.
/// * **A return is negative.** Both a credit note and a debit note are stored
///   with positive tax columns. Summing them as stored overstates outward
///   supply and input credit — money, in both directions.
void main() {
  late AppDatabase db;
  late String firmId;
  late ItemRepository items;
  late SalesRepository sales;
  late PurchaseRepository purchases;
  late PartyRepository parties;
  late String itemId;

  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Apex Traders',
      stateCode: '29',
      gstin: '29ABCDE1234F1Z5',
    );
    firmId = firm.id;
    items = db.itemRepositoryFor(firmId);
    sales = db.salesRepositoryFor(firmId);
    purchases = db.purchaseRepositoryFor(firmId);
    parties = db.partyRepositoryFor(firmId);

    final cement = await items.create(
      name: 'Cement',
      hsn: '2523',
      purchasePrice: 400,
      salePrice: 500,
      gstRate: 18,
    );
    itemId = cement.id;
    await items.create(
      name: 'Consulting',
      hsn: '998311',
      purchasePrice: 0,
      salePrice: 5000,
      gstRate: 18,
    );
  });

  tearDown(() => db.close());

  Future<String> party(
    String name, {
    String? gstin,
    String type = 'customer',
  }) async =>
      (await parties.create(name: name, type: type, gstin: gstin)).id;

  /// A sales invoice of one line, defaulted to something plausible so a test
  /// only states the thing it is actually about.
  Future<void> invoice({
    required String id,
    required DateTime date,
    required String partyId,
    String name = 'Cement',
    String hsn = '2523',
    String quantity = '10',
    String rate = '500',
    double gstRate = 18,
    String docType = 'invoice',
    TaxMode taxMode = TaxMode.exclusive,
    bool export = false,
    String? gstin,
  }) async {
    await sales.save(SalesDraft(
      id: id,
      number: id.toUpperCase(),
      invoiceDate: date,
      docType: docType,
      partyId: partyId,
      partyName: 'Customer',
      // Snapshotted onto the document, not read back from the party: the
      // GSTIN that goes on a return is the one the invoice was written with,
      // and a customer whose registration changed since must not retroactively
      // re-file every invoice under the new number.
      partyGstin: gstin,
      isExport: export,
      lines: [
        SalesLineDraft(
          id: '$id-l1',
          itemId: itemId,
          name: name,
          hsn: hsn,
          quantity: Decimal.parse(quantity),
          unit: 'bag',
          rate: Decimal.parse(rate),
          gstRate: gstRate,
          taxMode: taxMode,
        ),
      ],
    ));
  }

  Future<void> bill({
    required String id,
    required DateTime date,
    required String partyId,
    String name = 'Cement',
    String hsn = '2523',
    String quantity = '10',
    String rate = '400',
    double gstRate = 18,
    String docType = 'bill',
    String? supplierInvoice,
    String? gstin,
  }) async {
    await purchases.save(PurchaseDraft(
      id: id,
      number: id.toUpperCase(),
      billDate: date,
      docType: docType,
      partyId: partyId,
      partyName: 'Supplier',
      // Snapshotted onto the bill, for the same reason the sales side is: the
      // reconciliation keys on the supplier's GSTIN as it stood on the bill.
      partyGstin: gstin,
      supplierInvoiceNumber: supplierInvoice,
      lines: [
        PurchaseLineDraft(
          id: '$id-l1',
          itemId: itemId,
          name: name,
          hsn: hsn,
          quantity: Decimal.parse(quantity),
          unit: 'bag',
          rate: Decimal.parse(rate),
          gstRate: gstRate,
        ),
      ],
    ));
  }

  Future<List<ReportRow>> rowsFor(ReportDefinition definition) =>
      definition.source.build(db, firmId, window, const {});

  /// The one cell, by column key, with the spec's own column object so the
  /// value goes through `ReportRow.number` and its `negate` handling.
  Decimal value(ReportDefinition definition, ReportRow row, String key) {
    final column = definition.spec.columns.firstWhere((c) => c.key == key);
    return row.number(column);
  }

  String text(ReportDefinition definition, ReportRow row, String key) {
    final column = definition.spec.columns.firstWhere((c) => c.key == key);
    return row.text(column);
  }

  ReportRow only(ReportDefinition definition, List<ReportRow> rows) {
    expect(rows, hasLength(1), reason: 'expected exactly one row');
    return rows.single;
  }

  // ---------------------------------------------------------------- HSN ---

  group('Sale Summary By HSN', () {
    test('one row per HSN and rate, with the tax summed from the lines',
        () async {
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        quantity: '10',
        rate: '500',
      );

      final rows = await rowsFor(saleSummaryByHsn);
      expect(rows, hasLength(1));
      final row = only(saleSummaryByHsn, rows);

      expect(text(saleSummaryByHsn, row, 'hsn'), '2523');
      expect(text(saleSummaryByHsn, row, 'rate'), '18');
      // 10 x 500 = 5,000 taxable. An 18% intra-state rate splits 9% + 9%, so
      // 450 each, 900 of tax in total.
      expect(value(saleSummaryByHsn, row, 'taxable'), Decimal.fromInt(5000));
      expect(value(saleSummaryByHsn, row, 'cgst'), Decimal.fromInt(450));
      expect(value(saleSummaryByHsn, row, 'sgst'), Decimal.fromInt(450));
      expect(value(saleSummaryByHsn, row, 'total'), Decimal.fromInt(900));
    });

    test('the same code at two rates is two rows, not one merged row',
        () async {
      // The defect this test exists for: keyed on HSN alone, the 5% and 18%
      // taxable values land in one row and the return files 7,000 against a
      // rate that never applied to all of it.
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-18',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        gstRate: 18,
      );
      await invoice(
        id: 'inv-5',
        date: DateTime(2026, 5, 3),
        partyId: customer,
        gstRate: 5,
      );

      final rows = await rowsFor(saleSummaryByHsn);
      expect(rows, hasLength(2));
      final rates = rows.map((r) => text(saleSummaryByHsn, r, 'rate')).toSet();
      expect(rates, {'18', '5'});

      // Each row carries only its own taxable value.
      final byRate = {
        for (final row in rows)
          text(saleSummaryByHsn, row, 'rate'):
              value(saleSummaryByHsn, row, 'taxable'),
      };
      expect(byRate['18'], Decimal.fromInt(5000));
      expect(byRate['5'], Decimal.fromInt(5000));
    });

    test('a credit note reduces the taxable value instead of adding to it',
        () async {
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        quantity: '10',
      );
      // 2 x 500 = 1,000 returned. Stored with **positive** tax columns, which is
      // how the app saves every note — the sign belongs to the doc type.
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 5, 9),
        partyId: customer,
        docType: 'credit_note',
        quantity: '2',
      );

      final rows = await rowsFor(saleSummaryByHsn);
      final row = only(saleSummaryByHsn, rows);

      // 5,000 invoiced less 1,000 returned; 900 of tax less 180.
      expect(value(saleSummaryByHsn, row, 'taxable'), Decimal.fromInt(4000));
      expect(value(saleSummaryByHsn, row, 'total'), Decimal.fromInt(720));
    });

    test('a line with no HSN is reported as "Not set", not dropped', () async {
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        hsn: '',
      );

      final rows = await rowsFor(saleSummaryByHsn);
      expect(text(saleSummaryByHsn, only(saleSummaryByHsn, rows), 'hsn'),
          'Not set');
    });

    test('cancelled documents and documents in the recycle bin are excluded',
        () async {
      final customer = await party('Buildmart');
      await invoice(id: 'inv-ok', date: DateTime(2026, 5, 2), partyId: customer);
      await invoice(
        id: 'inv-cancelled',
        date: DateTime(2026, 5, 3),
        partyId: customer,
      );
      await sales.markCancelled('inv-cancelled');

      final rows = await rowsFor(saleSummaryByHsn);
      final row = only(saleSummaryByHsn, rows);
      // One invoice's worth of taxable, not two.
      expect(value(saleSummaryByHsn, row, 'taxable'), Decimal.fromInt(5000));
    });

    test('an unregistered firm has no outward supply to file', () async {
      final other = await db.firmRepository.create(
        name: ' unregistered firm',
        stateCode: '29',
      );
      final rows =
          await saleSummaryByHsn.source.build(db, other.id, window, const {});
      expect(rows, isEmpty,
          reason: 'a firm with no GSTIN files no GSTR-1 and no Table 12');
    });

    test('the rows carry every declared column, and the total is the tax',
        () async {
      final customer = await party('Buildmart');
      await invoice(id: 'inv-1', date: DateTime(2026, 5, 2), partyId: customer);
      final rows = await rowsFor(saleSummaryByHsn);
      // Folded through the real runner, not hand-assembled: the integrity check
      // compares groups against grand totals, and a hand-built result would
      // test a shape the app never constructs.
      final result = const ReportRunner().fold(
        spec: saleSummaryByHsn.spec,
        window: window,
        rows: rows,
      );
      expect(
        ReportIntegrityChecks.assertIntegrity(result).problems,
        isEmpty,
      );
    });
  });

  // ---------------------------------------------------------------- SAC ---

  group('SAC Report', () {
    test('inward supply by code and rate', () async {
      final supplier =
          await party('Cement Traders', type: 'vendor', gstin: '29AAACC0001A1Z5');
      await bill(id: 'bill-1', date: DateTime(2026, 5, 4), partyId: supplier);

      final rows = await rowsFor(sacReport);
      final row = only(sacReport, rows);
      expect(text(sacReport, row, 'hsn'), '2523');
      // 10 x 400 = 4,000 taxable; 18% intra-state splits 360 + 360.
      expect(value(sacReport, row, 'taxable'), Decimal.fromInt(4000));
      expect(value(sacReport, row, 'total'), Decimal.fromInt(720));
    });

    test('a debit note reduces input tax rather than adding to it', () async {
      final supplier =
          await party('Cement Traders', type: 'vendor', gstin: '29AAACC0001A1Z5');
      await bill(id: 'bill-1', date: DateTime(2026, 5, 4), partyId: supplier);
      await bill(
        id: 'dn-1',
        date: DateTime(2026, 5, 11),
        partyId: supplier,
        docType: 'debit_note',
        quantity: '2',
      );

      final rows = await rowsFor(sacReport);
      final row = only(sacReport, rows);
      // An overstated ITC is a credit paid out of pocket, so the sign is the
      // whole test: 4,000 less 800.
      expect(value(sacReport, row, 'taxable'), Decimal.fromInt(3200));
    });

    test('a cancelled bill is not an inward supply', () async {
      final supplier =
          await party('Cement Traders', type: 'vendor', gstin: '29AAACC0001A1Z5');
      await bill(id: 'bill-1', date: DateTime(2026, 5, 4), partyId: supplier);
      await bill(id: 'bill-2', date: DateTime(2026, 5, 5), partyId: supplier);
      // Cancelled straight on the row: unlike sales, `PurchaseRepository` has no
      // markCancelled, and the status column is what the live predicate reads.
      await (db.update(db.purchaseBills)
            ..where((b) => b.id.equals('bill-2')))
          .write(const PurchaseBillsCompanion(status: Value('cancelled')));

      final rows = await rowsFor(sacReport);
      expect(value(sacReport, only(sacReport, rows), 'taxable'),
          Decimal.fromInt(4000));
    });

    test('an unregistered firm files no return', () async {
      final other = await db.firmRepository.create(name: 'Plain', stateCode: '29');
      expect(
          await sacReport.source.build(db, other.id, window, const {}), isEmpty);
    });
  });

  // ------------------------------------------------------------ GSTR-3B ---

  group('GSTR 3B', () {
    test('3.1(a) carries the outward liability and the tables around it carry '
        'no invented figures', () async {
      final customer = await party('Buildmart');
      await invoice(id: 'inv-1', date: DateTime(2026, 5, 2), partyId: customer);

      final rows = await rowsFor(gstr3b);
      final byTable = {
        for (final row in rows) text(gstr3b, row, 'table'): row,
      };

      final outer = byTable['3.1(a)']!;
      expect(value(gstr3b, outer, 'taxable'), Decimal.fromInt(5000));
      // 450 + 450 = the whole outward liability for the period.
      expect(value(gstr3b, outer, 'total'), Decimal.fromInt(900));

      // A firm with no exports has 3.1(b) as zero — present, not missing.
      expect(byTable.containsKey('3.1(b)'), isTrue);
      expect(value(gstr3b, byTable['3.1(b)']!, 'taxable'), Decimal.zero);
      expect(value(gstr3b, byTable['3.1(b)']!, 'total'), Decimal.zero);
    });

    test('net ITC is 4(A) less 4(B)', () async {
      final supplier =
          await party('Cement Traders', type: 'vendor', gstin: '29AAACC0001A1Z5');
      // The GSTIN matters here: ITC is only available on inward supplies from a
      // registered supplier, so a bill without one is Table 5 nil-rated and
      // carries no credit at all.
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: supplier,
        gstin: '29AAACC0001A1Z5',
      );

      final rows = await rowsFor(gstr3b);
      final byTable = {
        for (final row in rows) text(gstr3b, row, 'table'): row,
      };
      // 18% of 4,000 = 720 input tax, no reversals.
      expect(value(gstr3b, byTable['4(A)(5)']!, 'total'), Decimal.fromInt(720));
      expect(value(gstr3b, byTable['Net ITC']!, 'total'), Decimal.fromInt(720));
    });

    test('the report agrees with the builder it reads from', () async {
      final customer = await party('Buildmart');
      await invoice(id: 'inv-1', date: DateTime(2026, 5, 2), partyId: customer);

      // The builder is called with the same window the report used, resolved the
      // same way — which is itself part of the claim: the report defaults an
      // open-ended window, and so must this.
      final builder = await buildGstr3b(
        db,
        firmId,
        from: windowFrom(window),
        to: windowTo(window),
      );
      final rows = await rowsFor(gstr3b);
      final outer = rows.firstWhere((r) => text(gstr3b, r, 'table') == '3.1(a)');

      // The point of sourcing from the builder: two implementations of the
      // outward supply would eventually disagree, and the reader would file
      // whichever they trusted.
      expect(value(gstr3b, outer, 'taxable'), builder.outwardTaxable);
      expect(value(gstr3b, outer, 'total'),
          builder.outwardIgst +
              builder.outwardCgst +
              builder.outwardSgst +
              builder.outwardCess);
    });

    test('an unregistered firm files no 3B', () async {
      final other = await db.firmRepository.create(name: 'Plain', stateCode: '29');
      expect(await gstr3b.source.build(db, other.id, window, const {}), isEmpty);
    });
  });

  // -------------------------------------------------------------- GSTR-1 ---

  group('GSTR 1', () {
    test('a registered customer lands in B2B with the taxable value, not the '
        'invoice face value', () async {
      final customer =
          await party('Buildmart', gstin: '29AAAAA0000A1Z5');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        gstin: '29AAAAA0000A1Z5',
      );

      final rows = await rowsFor(gstr1);
      final b2b = rows.firstWhere((r) => text(gstr1, r, 'table') == '4A / 4B');

      // 5,000 taxable. The invoice's `val` is 5,900 with tax; filing that as
      // the taxable value inflates Table 4 by exactly the tax charged.
      expect(value(gstr1, b2b, 'taxable'), Decimal.fromInt(5000));
      expect(value(gstr1, b2b, 'taxable'), isNot(Decimal.fromInt(5900)));
      expect(value(gstr1, b2b, 'total'), Decimal.fromInt(900));
    });

    test('an export is filed under place of supply 96, with no tax', () async {
      final overseas = await party('Emirates Trading');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: overseas,
        export: true,
        // An export carries no counterparty GSTIN — that is what makes it
        // unregistered B2C supply filed under 96.
      );

      final rows = await rowsFor(gstr1);
      final exportRow =
          rows.firstWhere((r) => text(gstr1, r, 'table') == '13A');

      expect(value(gstr1, exportRow, 'taxable'), Decimal.fromInt(5000));
      // Zero-rated means no tax, and a return claiming IGST on an export is
      // rejected.
      expect(value(gstr1, exportRow, 'total'), Decimal.zero);
    });

    test('Table 7 shows no document count rather than a false zero', () async {
      final walkIn = await party('Walk-in');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: walkIn,
        quantity: '1',
        rate: '500',
      );

      final rows = await rowsFor(gstr1);
      final table7 = rows.firstWhere((r) => text(gstr1, r, 'table') == '7');

      // The portal aggregates Table 7 by place and rate, so there is no count
      // to show. A zero here would claim the firm sold nothing.
      expect(text(gstr1, table7, 'count'), '—');
      expect(value(gstr1, table7, 'taxable'), Decimal.fromInt(500));
    });

    test('every return table appears, empty or not', () async {
      final rows = await rowsFor(gstr1);
      final tables = rows.map((r) => text(gstr1, r, 'table')).toSet();

      // An empty table that simply is not shown is indistinguishable from one
      // the builder forgot to fill.
      expect(tables, containsAll(['4A / 4B', '6B / 6C', '7', '13A', '13B']));
    });

    test('an unregistered firm files no GSTR-1', () async {
      final other = await db.firmRepository.create(name: 'Plain', stateCode: '29');
      expect(await gstr1.source.build(db, other.id, window, const {}), isEmpty);
    });
  });

  // -------------------------------------------------------------- GSTR-9 ---

  group('GSTR 9', () {
    test('sums the year\'s outward supply and adds the recorded adjustments',
        () async {
      final customer = await party('Buildmart');
      await invoice(id: 'inv-apr', date: DateTime(2026, 4, 10), partyId: customer);
      await invoice(id: 'inv-may', date: DateTime(2026, 5, 10), partyId: customer);

      final rows = await rowsFor(gstr9);
      final table4 =
          rows.firstWhere((r) => text(gstr9, r, 'table') == '4');
      // Two invoices of 5,000 across two months of the window.
      expect(value(gstr9, table4, 'amount'), Decimal.fromInt(10000));
    });

    test('an adjustment stored as a positive amount reduces the figure',
        () async {
      final customer = await party('Buildmart');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);

      await db.into(db.gstr9Adjustments).insert(Gstr9AdjustmentsCompanion.insert(
        id: 'adj-1',
        firmId: firmId,
        schedule: '4',
        description: 'Invoice reported in the wrong year',
        amount: 1500,
        direction: const Value('reduction'),
        date: DateTime(2026, 6, 30),
        financialYearStart: DateTime(2026, 4, 1),
      ));

      final rows = await rowsFor(gstr9);
      final adjustment = rows.firstWhere((r) =>
          text(gstr9, r, 'description').startsWith('Adjustment'));
      // Stored positive, filed as a reduction. Adding it would overstate the
      // return by 3,000.
      expect(value(gstr9, adjustment, 'amount'), Decimal.fromInt(-1500));
    });

    test('an addition is added', () async {
      await db.into(db.gstr9Adjustments).insert(Gstr9AdjustmentsCompanion.insert(
        id: 'adj-1',
        firmId: firmId,
        schedule: '4',
        description: 'Invoice missed until the annual return',
        amount: 2500,
        direction: const Value('addition'),
        date: DateTime(2026, 6, 30),
        financialYearStart: DateTime(2026, 4, 1),
      ));

      final rows = await rowsFor(gstr9);
      final adjustment = rows.firstWhere((r) =>
          text(gstr9, r, 'description').startsWith('Adjustment'));
      expect(value(gstr9, adjustment, 'amount'), Decimal.fromInt(2500));
    });
  });

  // --------------------------------------------------------- GSTR-2A rec ---

  group('GSTR-2A Reconciliation', () {
    test('with nothing imported it reports nothing rather than "all match"',
        () async {
      final supplier =
          await party('Cement Traders', type: 'vendor', gstin: '29AAACC0001A1Z5');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: supplier,
        supplierInvoice: 'SUP-1',
        gstin: '29AAACC0001A1Z5',
      );

      final rows = await rowsFor(gstr2aReconciliation);
      // The dangerous answer is "every invoice matched" from comparing the
      // books against nothing — that is a clean bill of health nobody earned.
      expect(rows, isEmpty);
    });

    test('an invoice the supplier never reported is called books-only',
        () async {
      final supplier =
          await party('Cement Traders', type: 'vendor', gstin: '29AAACC0001A1Z5');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: supplier,
        supplierInvoice: 'SUP-1',
        gstin: '29AAACC0001A1Z5',
      );

      // A portal file that reports nothing at all for this supplier.
      await storeImportedGstr2a(db, firmId, DateTime(2026, 4), {
        'b2b': <Object?>[],
      });

      final rows = await rowsFor(gstr2aReconciliation);
      final row = only(gstr2aReconciliation, rows);
      expect(text(gstr2aReconciliation, row, 'status'),
          'In your books, not in 2A');
      // Positive difference: credit recorded that will be blocked.
      expect(value(gstr2aReconciliation, row, 'difference'),
          Decimal.fromInt(720));
    });

    test('an invoice the supplier reported and the firm did not is 2A-only',
        () async {
      final supplier =
          await party('Cement Traders', type: 'vendor', gstin: '29AAACC0001A1Z5');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: supplier,
        supplierInvoice: 'SUP-1',
        gstin: '29AAACC0001A1Z5',
      );

      await storeImportedGstr2a(db, firmId, DateTime(2026, 4), {
        'b2b': [
          {
            'ctin': '29AAACC0001A1Z5',
            'trdnm': 'Cement Traders',
            'inv': [
              {
                'inum': 'SUP-9',
                'idt': '09-05-2026',
                'val': 4000.0,
                'itms': [
                  {
                    'itm_det': {
                      'txval': 4000.0,
                      'iamt': 0.0,
                      'camt': 360.0,
                      'samt': 360.0,
                      'csamt': 0.0,
                    }
                  }
                ],
              }
            ],
          }
        ],
      });

      final rows = await rowsFor(gstr2aReconciliation);
      final row = rows.firstWhere(
          (r) => text(gstr2aReconciliation, r, 'status') == 'In 2A, not in your books');
      // Negative difference: credit available that has not been claimed.
      expect(value(gstr2aReconciliation, row, 'difference'),
          Decimal.fromInt(-720));
    });

    test('a matching invoice reads as matched, with no difference', () async {
      final supplier =
          await party('Cement Traders', type: 'vendor', gstin: '29AAACC0001A1Z5');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: supplier,
        supplierInvoice: 'SUP-1',
        gstin: '29AAACC0001A1Z5',
      );

      await storeImportedGstr2a(db, firmId, DateTime(2026, 4), {
        'b2b': [
          {
            'ctin': '29AAACC0001A1Z5',
            'trdnm': 'Cement Traders',
            'inv': [
              {
                'inum': 'SUP-1',
                'idt': '04-05-2026',
                'val': 4000.0,
                'itms': [
                  {
                    'itm_det': {
                      'txval': 4000.0,
                      'iamt': 0.0,
                      'camt': 360.0,
                      'samt': 360.0,
                      'csamt': 0.0,
                    }
                  }
                ],
              }
            ],
          }
        ],
      });

      final rows = await rowsFor(gstr2aReconciliation);
      final row = only(gstr2aReconciliation, rows);
      expect(text(gstr2aReconciliation, row, 'status'), 'Matched');
      expect(value(gstr2aReconciliation, row, 'difference'), Decimal.zero);
    });

    test('the file is read per return period, not per firm', () async {
      // **April's bill exists, and May's file is imported.** If the lookup is
      // keyed only by firm, April finds May's file, matches this bill against
      // it and reports a difference — a reconciliation of one month against
      // another's return, which is exactly how a clean April gets a page of
      // phantom mismatches.
      final supplier =
          await party('Cement Traders', type: 'vendor', gstin: '29AAACC0001A1Z5');
      await bill(
        id: 'bill-apr',
        date: DateTime(2026, 4, 4),
        partyId: supplier,
        supplierInvoice: 'SUP-APR',
        gstin: '29AAACC0001A1Z5',
      );

      await storeImportedGstr2a(db, firmId, DateTime(2026, 5), {
        'b2b': [
          {
            'ctin': '29AAACC0001A1Z5',
            'trdnm': 'Cement Traders',
            'inv': [
              {
                'inum': 'SUP-APR',
                'idt': '04-04-2026',
                'val': 4000.0,
                'itms': [
                  {
                    'itm_det': {
                      'txval': 4000.0,
                      'iamt': 0.0,
                      'camt': 360.0,
                      'samt': 360.0,
                      'csamt': 0.0,
                    }
                  }
                ],
              }
            ],
          }
        ],
      });

      final april = ReportWindow(
        preset: ReportWindowPreset.custom,
        from: DateTime(2026, 4, 1),
        to: DateTime(2026, 4, 30, 23, 59, 59),
      );
      // No April file imported, so there is nothing to reconcile against.
      expect(
        await gstr2aReconciliation.source.build(db, firmId, april, const {}),
        isEmpty,
      );

      // And the May window does find its own file — so this is a lookup keyed
      // per period, not a lookup that finds nothing at all.
      final may = ReportWindow(
        preset: ReportWindowPreset.custom,
        from: DateTime(2026, 5, 1),
        to: DateTime(2026, 5, 31, 23, 59, 59),
      );
      expect(
        await gstr2aReconciliation.source.build(db, firmId, may, const {}),
        isNotEmpty,
      );
    });
  });

  // ------------------------------------------------------------ catalogue ---

  test('all six GST reports are registered and none is a placeholder', () {
    for (final id in [
      'gstr1',
      'gstr2a_reconciliation',
      'gstr3b',
      'gstr9',
      'sale_summary_by_hsn',
      'sac_report',
    ]) {
      final definition = ReportCatalogue.byId(id);
      expect(definition, isNotNull, reason: '$id must be in the catalogue');
      expect(
        ReportCatalogue.implemented.map((d) => d.spec.id),
        contains(id),
        reason: '$id must have a real source, not a placeholder',
      );
    }
  });
}
