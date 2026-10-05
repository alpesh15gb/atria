import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/item_repository.dart';
import 'package:atria/core/database/repositories/party_repository.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_runner.dart';
import 'package:atria/core/reports/sources/business_status/discount_report.dart';
import 'package:atria/core/reports/sources/business_status/gst_rate_report.dart';
import 'package:atria/core/reports/sources/item_stock/item_common.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 4e — Business Status.
///
/// Two reports, and both are about a *period* rather than a position, so the
/// window is load-bearing rather than decorative.
///
/// The fixtures are built so the wrong answer is a **different number**, never a
/// missing row: a credit note against a sale (which must reduce a discount, not
/// add one), an invoice-level allowance whose share has to be recovered from the
/// books rather than divided again, and the same item sold at two different GST
/// rates in the same month (which must be two bands).
void main() {
  late AppDatabase db;
  late String firmId;
  late ItemRepository items;
  late SalesRepository sales;
  late PartyRepository parties;
  late String cementId;
  late String serviceId;

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
    parties = db.partyRepositoryFor(firmId);

    cementId = (await items.create(
      name: 'Cement',
      hsn: '2523',
      purchasePrice: 400,
      salePrice: 500,
      gstRate: 18,
    ))
        .id;
    // A **service**, so the rate report has to separate HSN from SAC: same 18%
    // rate, different return table. The flag is what the report reads — an HSN
    // of 998311 on its own does not make an item a service.
    serviceId = (await items.create(
      name: 'Consulting',
      hsn: '998311',
      purchasePrice: 0,
      salePrice: 5000,
      gstRate: 18,
      isService: true,
    ))
        .id;
  });

  tearDown(() => db.close());

  Future<String> party(String name) async =>
      (await parties.create(name: name, type: 'customer')).id;

  Future<void> invoice({
    required String id,
    required DateTime date,
    required String partyId,
    String? itemId,
    String name = 'Cement',
    String quantity = '10',
    String rate = '500',
    double gstRate = 18,
    String discountPercent = '',
    String discountAmount = '',
    Decimal? invoiceDiscountAmount,
    String docType = 'invoice',
  }) async {
    await sales.save(SalesDraft(
      id: id,
      number: id.toUpperCase(),
      invoiceDate: date,
      docType: docType,
      partyId: partyId,
      partyName: 'Customer',
      invoiceDiscountAmount: invoiceDiscountAmount,
      lines: [
        SalesLineDraft(
          id: '$id-l1',
          itemId: itemId ?? cementId,
          name: name,
          hsn: itemId == serviceId ? '998311' : '2523',
          quantity: Decimal.parse(quantity),
          unit: 'bag',
          rate: Decimal.parse(rate),
          discountPercent: discountPercent.isEmpty
              ? Decimal.zero
              : Decimal.parse(discountPercent),
          discountAmount: discountAmount.isEmpty
              ? null
              : Decimal.parse(discountAmount),
          gstRate: gstRate,
        ),
      ],
    ));
  }

  Future<List<ReportRow>> rowsFor(ReportDefinition definition,
          {Map<String, Object?> filters = const {}}) =>
      definition.source.build(db, firmId, window, filters);

  Decimal value(ReportDefinition definition, ReportRow row, String key) {
    final column = definition.spec.columns.firstWhere((c) => c.key == key);
    return row.number(column);
  }

  String text(ReportDefinition definition, ReportRow row, String key) {
    final column = definition.spec.columns.firstWhere((c) => c.key == key);
    return row.text(column);
  }

  // ------------------------------------------------------------ GST Rate ---

  group('GST Rate Report', () {
    test('one band per rate actually charged, with the tax that went with it',
        () async {
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
      );

      final rows = await rowsFor(gstRateReport);
      expect(rows, hasLength(1));
      final row = rows.single;

      expect(text(gstRateReport, row, 'rate'), '18');
      expect(text(gstRateReport, row, 'supply'), 'Goods (HSN)');
      expect(value(gstRateReport, row, 'taxable'), Decimal.fromInt(5000));
      // 18% intra-state splits 9 + 9.
      expect(value(gstRateReport, row, 'cgst'), Decimal.fromInt(450));
      expect(value(gstRateReport, row, 'sgst'), Decimal.fromInt(450));
      expect(value(gstRateReport, row, 'tax'), Decimal.fromInt(900));
      expect(value(gstRateReport, row, 'documents'), Decimal.one);
    });

    test('the same rate on goods and on services is two bands', () async {
      // Both at 18%, but filed under HSN and SAC respectively — merging them
      // would file a service under a goods code on the return.
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-goods',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        quantity: '10',
      );
      await invoice(
        id: 'inv-service',
        date: DateTime(2026, 5, 3),
        partyId: customer,
        itemId: serviceId,
        name: 'Consulting',
        quantity: '1',
        rate: '5000',
      );

      final rows = await rowsFor(gstRateReport);
      expect(rows, hasLength(2));

      final supplies = rows.map((r) => text(gstRateReport, r, 'supply')).toSet();
      expect(supplies, {'Goods (HSN)', 'Services (SAC)'});

      // Both bands count their own documents, so the two figures add up.
      final documents = rows
          .map((r) => value(gstRateReport, r, 'documents'))
          .reduce((a, b) => a + b);
      expect(documents, Decimal.fromInt(2));
    });

    test('one invoice with two lines at one rate is one document', () async {
      // The count is documents, not lines: "2 documents" for a single invoice
      // is a number that never existed.
      final customer = await party('Buildmart');
      await sales.save(SalesDraft(
        id: 'inv-two-lines',
        number: 'INV-TWO',
        invoiceDate: DateTime(2026, 5, 2),
        docType: 'invoice',
        partyId: customer,
        partyName: 'Customer',
        lines: [
          SalesLineDraft(
            id: 'l1',
            itemId: cementId,
            name: 'Cement',
            hsn: '2523',
            quantity: Decimal.fromInt(5),
            unit: 'bag',
            rate: Decimal.fromInt(500),
            gstRate: 18,
          ),
          SalesLineDraft(
            id: 'l2',
            itemId: cementId,
            name: 'Cement',
            hsn: '2523',
            quantity: Decimal.fromInt(5),
            unit: 'bag',
            rate: Decimal.fromInt(500),
            gstRate: 18,
          ),
        ],
      ));

      final rows = await rowsFor(gstRateReport);
      expect(value(gstRateReport, rows.single, 'documents'), Decimal.one);
      expect(value(gstRateReport, rows.single, 'taxable'), Decimal.fromInt(5000));
    });

    test('two different rates in one period are two bands', () async {
      // The rate is derived from each line's own tax. Reading the item
      // master's rate collapses these into one band and files the 5% sales
      // against 18%.
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

      final rows = await rowsFor(gstRateReport);
      expect(rows, hasLength(2));
      expect(rows.map((r) => text(gstRateReport, r, 'rate')).toSet(), {'18', '5'});
    });

    test('a credit note reduces its band rather than adding a new one',
        () async {
      final customer = await party('Buildmart');
      await invoice(id: 'inv-1', date: DateTime(2026, 5, 2), partyId: customer);
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 5, 9),
        partyId: customer,
        docType: 'credit_note',
        quantity: '2',
      );

      final rows = await rowsFor(gstRateReport);
      expect(rows, hasLength(1));
      // 5,000 invoiced less 1,000 returned, on the same band.
      expect(value(gstRateReport, rows.single, 'taxable'), Decimal.fromInt(4000));
      expect(value(gstRateReport, rows.single, 'tax'), Decimal.fromInt(720));
    });

    test('a nil-rated line is a band, not an absence', () async {
      // A report of "tax collected" that silently drops the exempt sales is a
      // different document from the one the portal asks for.
      final customer = await party('Walk-in');
      await invoice(
        id: 'inv-0',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        gstRate: 0,
      );

      final rows = await rowsFor(gstRateReport);
      expect(rows, hasLength(1));
      expect(text(gstRateReport, rows.single, 'rate'), '0');
      expect(value(gstRateReport, rows.single, 'taxable'), Decimal.fromInt(5000));
      expect(value(gstRateReport, rows.single, 'tax'), Decimal.zero);
    });

    test('a cancelled invoice contributes nothing', () async {
      final customer = await party('Buildmart');
      await invoice(id: 'inv-ok', date: DateTime(2026, 5, 2), partyId: customer);
      await invoice(
        id: 'inv-cancelled',
        date: DateTime(2026, 5, 3),
        partyId: customer,
      );
      await sales.markCancelled('inv-cancelled');

      final rows = await rowsFor(gstRateReport);
      expect(value(gstRateReport, rows.single, 'taxable'), Decimal.fromInt(5000));
    });
  });

  // ----------------------------------------------------------- Discount ---

  group('Discount Report', () {
    test('gross less discount equals net on every row', () async {
      // The identity the footnote promises and the reader is invited to check.
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        discountAmount: '500',
      );

      final rows = await rowsFor(discountReport);
      final row = rows.single;

      // 10 x 500 = 5,000 before any allowance.
      expect(value(discountReport, row, 'gross'), Decimal.fromInt(5000));
      expect(value(discountReport, row, 'discount'), Decimal.fromInt(500));
      expect(value(discountReport, row, 'net'), Decimal.fromInt(4500));
      expect(
        value(discountReport, row, 'gross') - value(discountReport, row, 'discount'),
        value(discountReport, row, 'net'),
      );
      // 500 off 5,000 is 10%.
      expect(value(discountReport, row, 'percent'), Decimal.fromInt(10));
    });

    test('the invoice allowance is recovered from the books, not divided again',
        () async {
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        invoiceDiscountAmount: Decimal.fromInt(900),
      );

      final row = (await rowsFor(discountReport)).single;

      // The engine apportioned the ₹900 across this one line, so its share is
      // the whole allowance — and the identity still holds.
      expect(value(discountReport, row, 'invoiceDiscount'), Decimal.fromInt(900));
      expect(value(discountReport, row, 'discount'), Decimal.fromInt(900));
      expect(value(discountReport, row, 'net'), Decimal.fromInt(4100));
    });

    test('an allowance split across three equal lines apportions exactly',
        () async {
      // ₹10 across three equal lines is 3.33 / 3.33 / 3.34 under largest
      // remainder. Dividing the header again produces a *different* set, and
      // the reader's check of gross − discount == net then fails on two of the
      // three rows by a paisa.
      final customer = await party('Buildmart');
      await sales.save(SalesDraft(
        id: 'inv-split',
        number: 'INV-SPLIT',
        invoiceDate: DateTime(2026, 5, 2),
        docType: 'invoice',
        partyId: customer,
        partyName: 'Customer',
        invoiceDiscountAmount: Decimal.fromInt(10),
        lines: [
          for (var i = 0; i < 3; i++)
            SalesLineDraft(
              id: 'l$i',
              itemId: cementId,
              name: 'Cement',
              hsn: '2523',
              quantity: Decimal.fromInt(1),
              unit: 'bag',
              rate: Decimal.fromInt(100),
              gstRate: 0,
            ),
        ],
      ));

      final row = (await rowsFor(discountReport)).single;

      // Gross 300, the whole ₹10 allowance, net 290 — exactly.
      expect(value(discountReport, row, 'gross'), Decimal.fromInt(300));
      expect(
        value(discountReport, row, 'invoiceDiscount'),
        Decimal.fromInt(10),
        reason: 'the shares must sum to the header allowance exactly',
      );
      expect(value(discountReport, row, 'net'), Decimal.fromInt(290));
    });

    test('a line discount and an invoice allowance are both counted', () async {
      // They are different columns on the document; printing only one
      // understates the discount by the other.
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        discountAmount: '200',
        invoiceDiscountAmount: Decimal.fromInt(300),
      );

      final row = (await rowsFor(discountReport)).single;
      expect(value(discountReport, row, 'lineDiscount'), Decimal.fromInt(200));
      expect(
          value(discountReport, row, 'invoiceDiscount'), Decimal.fromInt(300));
      expect(value(discountReport, row, 'discount'), Decimal.fromInt(500));
      expect(value(discountReport, row, 'net'), Decimal.fromInt(4500));
    });

    test('a percentage discount is honoured', () async {
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        discountPercent: '10',
      );

      final row = (await rowsFor(discountReport)).single;
      expect(value(discountReport, row, 'gross'), Decimal.fromInt(5000));
      expect(value(discountReport, row, 'discount'), Decimal.fromInt(500));
      expect(value(discountReport, row, 'net'), Decimal.fromInt(4500));
    });

    test('a credit note takes the discount back off', () async {
      // A returned sale was discounted *less* over the period, not more.
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        discountAmount: '100',
      );
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 5, 9),
        partyId: customer,
        docType: 'credit_note',
        quantity: '2',
        discountAmount: '20',
      );

      final row = (await rowsFor(discountReport)).single;
      expect(value(discountReport, row, 'gross'), Decimal.fromInt(4000));
      expect(value(discountReport, row, 'discount'), Decimal.fromInt(80));
      expect(value(discountReport, row, 'net'), Decimal.fromInt(3920));
    });

    test('rows accumulate per item across the period', () async {
      final customer = await party('Buildmart');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 5, 2),
        partyId: customer,
        discountAmount: '100',
      );
      await invoice(
        id: 'inv-2',
        date: DateTime(2026, 6, 2),
        partyId: customer,
        discountAmount: '300',
      );

      final rows = await rowsFor(discountReport);
      expect(rows, hasLength(1));
      expect(value(discountReport, rows.single, 'discount'), Decimal.fromInt(400));
    });

    test('the item filter narrows the report', () async {
      final customer = await party('Buildmart');
      await invoice(id: 'inv-goods', date: DateTime(2026, 5, 2), partyId: customer);
      await invoice(
        id: 'inv-service',
        date: DateTime(2026, 5, 3),
        partyId: customer,
        itemId: serviceId,
        name: 'Consulting',
        quantity: '1',
        rate: '5000',
      );

      final all = await rowsFor(discountReport);
      expect(all, hasLength(2));

      final filtered = await rowsFor(
        discountReport,
        filters: {kItemFilterId: cementId},
      );
      expect(filtered, hasLength(1));
      expect(text(discountReport, filtered.single, 'item'), 'Cement');
    });

    test('an undiscounted sale reports a zero, not a blank', () async {
      // `assertIntegrity` fails a declared column nothing fills, and a blank
      // discount is indistinguishable from one nobody computed.
      final customer = await party('Buildmart');
      await invoice(id: 'inv-1', date: DateTime(2026, 5, 2), partyId: customer);

      final result = const ReportRunner().fold(
        spec: discountReport.spec,
        window: window,
        rows: await rowsFor(discountReport),
      );
      expect(ReportIntegrityChecks.assertIntegrity(result).problems, isEmpty);
    });
  });

  test('both Business Status reports are real sources, not placeholders', () {
    expect(
      ReportCatalogue.implemented.map((d) => d.spec.id),
      containsAll(['gst_rate_report', 'discount_report']),
    );
  });
}