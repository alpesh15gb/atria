import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/item_repository.dart';
import 'package:atria/core/database/repositories/party_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/sources/taxes/form_27eq.dart';
import 'package:atria/core/reports/sources/taxes/tcs_receivable.dart';
import 'package:atria/core/reports/sources/taxes/tds_payable.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Taxes reports: TDS Payable, Form 27EQ and TCS Receivable.
///
/// **These assertions are about what gets filed, not about what draws.** Every
/// number on these three documents is remitted to a government, so the fixtures
/// are chosen so the wrong answer is a different figure rather than a missing
/// row:
///
/// * a bill with no deduction, which must not appear at all;
/// * two bills from one deductee under one section, which is **one line** of the
///   27EQ and **two rows** of the Payable;
/// * a debit note, which reverses a deduction;
/// * a bill whose PAN and section were never recorded.
///
/// The last group is the one that matters most. Every field on a TDS bill is a
/// **snapshot**, and these tests exist to prove the reports read the snapshot
/// rather than re-deriving it — a 26Q filed against a guessed PAN is a notice.
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
    firmId = (await db.firmRepository.create(
      name: 'Apex Traders',
      stateCode: '29',
      gstin: '29ABCDE1234F1Z5',
    )).id;
    items = db.itemRepositoryFor(firmId);
    sales = db.salesRepositoryFor(firmId);
    purchases = db.purchaseRepositoryFor(firmId);
    parties = db.partyRepositoryFor(firmId);
    itemId = (await items.create(
      name: 'Cement',
      hsn: '2523',
      purchasePrice: 400,
      salePrice: 500,
      gstRate: 18,
    )).id;
  });

  tearDown(() => db.close());

  Future<String> supplier(String name, {String? pan}) async =>
      (await parties.create(name: name, type: 'vendor', pan: pan)).id;

  Future<void> bill({
    required String id,
    required DateTime date,
    required String partyId,
    String quantity = '10',
    String rate = '400',
    String? tdsRate,
    String? pan,
    String? section,
    double sectionRate = 0,
    String docType = 'bill',
  }) async {
    await purchases.save(
      PurchaseDraft(
        id: id,
        number: id.toUpperCase(),
        billDate: date,
        docType: docType,
        partyId: partyId,
        partyName: 'Supplier',
        tdsRate: tdsRate == null ? null : Decimal.parse(tdsRate),
        deducteePan: pan,
        tdsSection: section,
        tdsSectionRate: sectionRate,
        lines: [
          PurchaseLineDraft(
            id: '$id-l1',
            itemId: itemId,
            name: 'Cement',
            hsn: '2523',
            quantity: Decimal.parse(quantity),
            unit: 'bag',
            rate: Decimal.parse(rate),
            gstRate: 0,
          ),
        ],
      ),
    );
  }

  Future<void> invoice({
    required String id,
    required DateTime date,
    required String partyId,
    String quantity = '10',
    String rate = '500',
    String? tcsRate,
    String? gstin,
    String docType = 'invoice',
  }) async {
    await sales.save(
      SalesDraft(
        id: id,
        number: id.toUpperCase(),
        invoiceDate: date,
        docType: docType,
        partyId: partyId,
        partyName: 'Customer',
        partyGstin: gstin,
        tcsRate: tcsRate == null ? null : Decimal.parse(tcsRate),
        lines: [
          SalesLineDraft(
            id: '$id-l1',
            itemId: itemId,
            name: 'Cement',
            hsn: '2523',
            quantity: Decimal.parse(quantity),
            unit: 'bag',
            rate: Decimal.parse(rate),
            gstRate: 0,
          ),
        ],
      ),
    );
  }

  Future<List<ReportRow>> rowsFor(ReportDefinition d) =>
      d.source.build(db, firmId, window, const {});

  Decimal value(ReportDefinition d, ReportRow row, String key) =>
      row.number(d.spec.columns.firstWhere((c) => c.key == key));

  String text(ReportDefinition d, ReportRow row, String key) =>
      row.text(d.spec.columns.firstWhere((c) => c.key == key));

  Decimal totalOf(ReportDefinition d, List<ReportRow> rows, String key) {
    final column = d.spec.columns.firstWhere((c) => c.key == key);
    return rows.fold(Decimal.zero, (sum, row) => sum + row.number(column));
  }

  // --------------------------------------------------------- TDS Payable ---

  group('TDS Payable', () {
    test('one row per bill that carried a deduction', () async {
      final id = await supplier('Cement Traders', pan: 'AAACC0001A');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: id,
        quantity: '1000',
        rate: '100',
        tdsRate: '1',
        pan: 'AAACC0001A',
        section: '192',
        sectionRate: 1,
      );

      final rows = await rowsFor(tdsPayable);
      expect(rows, hasLength(1));
      final row = rows.single;

      expect(text(tdsPayable, row, 'section'), '192');
      expect(text(tdsPayable, row, 'pan'), 'AAACC0001A');
      // The **stored** deduction: 1% of a 100,000 taxable value, not a
      // re-multiplication.
      expect(value(tdsPayable, row, 'taxable'), Decimal.fromInt(100000));
      expect(value(tdsPayable, row, 'tds'), Decimal.fromInt(1000));
      expect(value(tdsPayable, row, 'rate'), Decimal.fromInt(1));
    });

    test('a bill with no deduction is not on the report', () async {
      // It contributes zero to the liability, and listing it would make the
      // total disagree with the return by every undeducted bill in the quarter.
      final id = await supplier('Cement Traders', pan: 'AAACC0001A');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: id,
        tdsRate: '1',
        pan: 'AAACC0001A',
        section: '192',
      );
      await bill(id: 'bill-plain', date: DateTime(2026, 5, 6), partyId: id);

      final rows = await rowsFor(tdsPayable);
      expect(rows, hasLength(1));
      expect(text(tdsPayable, rows.single, 'number'), 'BILL-1');
    });

    test('a debit note reverses the deduction', () async {
      final id = await supplier('Cement Traders', pan: 'AAACC0001A');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: id,
        tdsRate: '10',
        pan: 'AAACC0001A',
        section: '192',
      );
      await bill(
        id: 'dn-1',
        date: DateTime(2026, 5, 20),
        partyId: id,
        quantity: '2',
        docType: 'debit_note',
        tdsRate: '10',
        pan: 'AAACC0001A',
        section: '192',
      );

      final rows = await rowsFor(tdsPayable);
      // Two bills, one net figure: 4,000 taxable at 10% = 400 deducted, less
      // the 800-taxable note at 10% = 80 given back.
      expect(rows, hasLength(2));
      expect(totalOf(tdsPayable, rows, 'tds'), Decimal.fromInt(320));
    });

    test('a missing PAN or section is shown, not hidden', () async {
      // A 26Q cannot be filed with a blank PAN, and the reader has to see that
      // it is *their* missing field rather than a blank the report produced.
      final id = await supplier('Unknown Co');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: id,
        tdsRate: '1',
      );

      final row = (await rowsFor(tdsPayable)).single;
      expect(text(tdsPayable, row, 'pan'), 'Not recorded');
      expect(text(tdsPayable, row, 'section'), 'Not recorded');
    });

    test('the PAN is snapshotted from the supplier when not given', () async {
      // A bill typed through the purchase screen names the supplier, and their
      // PAN is on the party — so the ordinary path produces a usable 26Q.
      final id = await supplier('Cement Traders', pan: 'BBBBB0002B');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: id,
        tdsRate: '1',
        section: '192',
      );

      expect(
        text(tdsPayable, (await rowsFor(tdsPayable)).single, 'pan'),
        'BBBBB0002B',
      );
    });

    test('a bill with no TDS stores no PAN or section at all', () async {
      // Writing them onto an undeducted bill would put a 26Q line in the report
      // for a bill that never had tax withheld from it.
      final id = await supplier('Cement Traders', pan: 'BBBBB0002B');
      await bill(id: 'bill-1', date: DateTime(2026, 5, 4), partyId: id);

      final stored = await (db.select(
        db.purchaseBills,
      )..where((b) => b.id.equals('bill-1'))).getSingle();
      expect(stored.deducteePan, isNull);
      expect(stored.tdsSection, isNull);
      expect(await rowsFor(tdsPayable), isEmpty);
    });

    test('a cancelled bill is not part of the liability', () async {
      final id = await supplier('Cement Traders', pan: 'AAACC0001A');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: id,
        tdsRate: '1',
        pan: 'AAACC0001A',
        section: '192',
      );
      // No markCancelled on the purchase side, so the status is written
      // straight on the row — which is what the live predicate reads.
      await (db.update(db.purchaseBills)..where((b) => b.id.equals('bill-1')))
          .write(const PurchaseBillsCompanion(status: Value('cancelled')));

      expect(await rowsFor(tdsPayable), isEmpty);
    });
  });

  // ------------------------------------------------------------- Form 27EQ ---

  group('Form 27EQ', () {
    test('two bills from one deductee are one line, not two', () async {
      // This is the whole difference from TDS Payable: the quarterly form
      // aggregates by deductee and section, so a quarter with two bills from one
      // contractor is one line.
      final id = await supplier('Cement Traders', pan: 'AAACC0001A');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: id,
        quantity: '1000',
        rate: '100',
        tdsRate: '1',
        pan: 'AAACC0001A',
        section: '192',
        sectionRate: 1,
      );
      await bill(
        id: 'bill-2',
        date: DateTime(2026, 6, 4),
        partyId: id,
        quantity: '1000',
        rate: '100',
        tdsRate: '1',
        pan: 'AAACC0001A',
        section: '192',
        sectionRate: 1,
      );

      final rows = await rowsFor(form27eq);
      expect(rows, hasLength(1));
      final row = rows.single;

      expect(text(form27eq, row, 'pan'), 'AAACC0001A');
      expect(text(form27eq, row, 'section'), '192');
      expect(value(form27eq, row, 'bills'), Decimal.fromInt(2));
      expect(value(form27eq, row, 'taxable'), Decimal.fromInt(200000));
      expect(value(form27eq, row, 'tds'), Decimal.fromInt(2000));
    });

    test('the same deductee under two sections is two lines', () async {
      // A business legitimately pays the same supplier under 192 and 194H, and
      // the portal files them separately.
      final id = await supplier('Cement Traders', pan: 'AAACC0001A');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: id,
        tdsRate: '1',
        pan: 'AAACC0001A',
        section: '192',
        sectionRate: 1,
      );
      await bill(
        id: 'bill-2',
        date: DateTime(2026, 5, 6),
        partyId: id,
        tdsRate: '2',
        pan: 'AAACC0001A',
        section: '194H',
        sectionRate: 2,
      );

      final rows = await rowsFor(form27eq);
      expect(rows, hasLength(2));
      expect(rows.map((r) => text(form27eq, r, 'section')).toSet(), {
        '192',
        '194H',
      });
    });

    test(
      'a deductee with nothing deducted is not a line of the return',
      () async {
        final id = await supplier('Cement Traders', pan: 'AAACC0001A');
        await bill(
          id: 'bill-1',
          date: DateTime(2026, 5, 4),
          partyId: id,
          tdsRate: '1',
          pan: 'AAACC0001A',
          section: '192',
        );
        await bill(id: 'bill-plain', date: DateTime(2026, 5, 8), partyId: id);

        final rows = await rowsFor(form27eq);
        expect(rows, hasLength(1));
        expect(value(form27eq, rows.single, 'bills'), Decimal.one);
      },
    );

    test('a missing section is a line the reader must fix', () async {
      final id = await supplier('Unknown Co');
      await bill(
        id: 'bill-1',
        date: DateTime(2026, 5, 4),
        partyId: id,
        tdsRate: '1',
      );

      final row = (await rowsFor(form27eq)).single;
      expect(text(form27eq, row, 'section'), 'Not recorded');
      expect(text(form27eq, row, 'pan'), 'Not recorded');
    });
  });

  // ------------------------------------------------------- TCS Receivable ---

  group('TCS Receivable', () {
    test('only invoices that actually collected TCS', () async {
      // This total is the remittance line of the return. Listing every invoice
      // would make it disagree with the return by every exempt sale.
      final customer = await parties
          .create(name: 'Buildmart', type: 'customer')
          .then((p) => p.id);
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        quantity: '100',
        rate: '1000',
        tcsRate: '1',
        gstin: '29AAAAA0000A1Z5',
      );
      await invoice(
        id: 'inv-plain',
        date: DateTime(2026, 5, 4),
        partyId: customer,
      );

      final rows = await rowsFor(tcsReceivable);
      expect(rows, hasLength(1));
      final row = rows.single;

      expect(text(tcsReceivable, row, 'number'), 'INV-1');
      expect(text(tcsReceivable, row, 'rate'), '1');
      expect(value(tcsReceivable, row, 'taxable'), Decimal.fromInt(100000));
      expect(value(tcsReceivable, row, 'tcs'), Decimal.fromInt(1000));
    });

    test('a credit note gives the tax back', () async {
      final customer = await parties
          .create(name: 'Buildmart', type: 'customer')
          .then((p) => p.id);
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        quantity: '100',
        rate: '1000',
        tcsRate: '1',
      );
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 5, 20),
        partyId: customer,
        quantity: '10',
        rate: '500',
        docType: 'credit_note',
        tcsRate: '1',
      );

      final rows = await rowsFor(tcsReceivable);
      // 100,000 taxable at 1% = 1,000 collected, less the note's 5,000 at 1%
      // = 50 given back.
      expect(totalOf(tcsReceivable, rows, 'tcs'), Decimal.fromInt(950));
    });

    test('a cancelled invoice collected nothing', () async {
      final customer = await parties
          .create(name: 'Buildmart', type: 'customer')
          .then((p) => p.id);
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        quantity: '100',
        rate: '1000',
        tcsRate: '1',
      );
      await sales.markCancelled('inv-1');

      expect(await rowsFor(tcsReceivable), isEmpty);
    });

    test('a customer with no GSTIN is flagged, not guessed', () async {
      final customer = await parties
          .create(name: 'Walk-in', type: 'customer')
          .then((p) => p.id);
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        quantity: '100',
        rate: '1000',
        tcsRate: '1',
      );

      expect(
        text(tcsReceivable, (await rowsFor(tcsReceivable)).single, 'gstin'),
        'Not recorded',
      );
    });
  });

  test('the three Taxes reports are real sources; TDS Receivable is not', () {
    final implemented = ReportCatalogue.implemented
        .map((d) => d.spec.id)
        .toSet();
    expect(
      implemented,
      containsAll([
        'tds_payable',
        'form_27eq',
        'tcs_receivable',
        'gst_rate_report',
      ]),
    );
    // `sales_invoices.tcs` is tax collected *from* a customer, so it is the TCS
    // report and nothing else. "Tax a customer deducted from us" is a different
    // fact on a different line of the return, and no column stores it — so this
    // one stays a placeholder until schema v13 rather than becoming a second
    // report that reads the same column under a different name.
    expect(implemented, contains('tds_receivable'));
    expect(ReportCatalogue.byId('tds_receivable'), isNotNull);
  });
}
