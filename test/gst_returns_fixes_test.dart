import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/reports/gst_return_builder.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression cover for the audited GST-return bugs that were silent — the
/// ones where the return filed with the government was wrong, or where three
/// screens disagreed about the same month:
///
///  * 3.1(a) absorbing the exempt half of a mixed-rate invoice (A6),
///  * GSTR-1 dropping every export/SEZ invoice (B15),
///  * the HSN table keyed on the code alone and carrying no rate (B16),
///  * ITC reversals floored at zero so 4(A)(5) over-claimed credit (D3),
///  * the Reports card / Dashboard disagreeing with the return (A7).
void main() {
  late AppDatabase db;
  late String firmId;

  final april = (
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 4, 30, 23, 59, 59),
  );

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Apex Integrations',
      stateCode: '36',
      gstin: '36CZFPM0045M2Z7',
    );
    firmId = firm.id;
  });

  tearDown(() => db.close());

  test('3.1(a)/3.1(c) split by LINE rate, and still add up to the document',
      () async {
    // One invoice, one taxable line and one exempt line. The document has
    // non-zero tax, so the old document-total test (`all four tax heads are
    // zero?`) put the WHOLE taxable value in 3.1(a) and 3.1(c) stayed 0.
    await db.salesRepositoryFor(firmId).save(SalesDraft(
      id: 'mixed-1',
      number: 'INV-MIX',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 4, 8),
      placeOfSupply: '36',
      lines: [
        SalesLineDraft(
          id: 'mixed-taxable',
          name: 'Printer',
          hsn: '8443',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('10000'),
          gstRate: 18,
        ),
        SalesLineDraft(
          id: 'mixed-exempt',
          name: 'Cotton waste',
          hsn: '6310',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('2000'),
          gstRate: 0,
        ),
      ],
    ));

    final report = await buildGstr3b(
      db,
      firmId,
      from: april.from,
      to: april.to,
    );

    expect(report.outwardTaxable, Decimal.parse('10000.00'),
        reason: 'only the 18% line is taxable outward supply');
    expect(report.nilRated, Decimal.parse('2000.00'),
        reason: 'the exempt line belongs in 3.1(c), not 3.1(a)');
    expect(
      report.outwardTaxable + report.nilRated,
      Decimal.parse('12000.00'),
      reason: 'the two rate buckets must still reconcile with the document '
          'total and with portal Table 4.1',
    );
    expect(report.outwardCgst, Decimal.parse('900.00'));
    expect(report.outwardSgst, Decimal.parse('900.00'));
  });

  test('an all-exempt invoice still lands wholly in 3.1(c)', () async {
    await db.salesRepositoryFor(firmId).save(SalesDraft(
      id: 'exempt-1',
      number: 'INV-EX',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 4, 8),
      lines: [
        SalesLineDraft(
          id: 'exempt-line',
          name: 'Cotton waste',
          hsn: '6310',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('5000'),
          gstRate: 0,
        ),
      ],
    ));

    final report =
        await buildGstr3b(db, firmId, from: april.from, to: april.to);
    expect(report.outwardTaxable, Decimal.zero);
    expect(report.nilRated, Decimal.parse('5000.00'));
  });

  test('exports are filed in EXPWP / EXPWOP, not dropped from GSTR-1',
      () async {
    final sales = db.salesRepositoryFor(firmId);
    await sales.save(SalesDraft(
      id: 'exp-wp',
      number: 'EXP-1',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 4, 9),
      partyName: 'Meridian Exports Ltd',
      partyGstin: '36AABCK1234M1Z5',
      placeOfSupply: '36',
      isInterState: true,
      isExport: true,
      exportType: 'wp',
      lines: [
        SalesLineDraft(
          id: 'exp-wp-line',
          name: 'Cotton fabric',
          hsn: '5208',
          quantity: Decimal.fromInt(10),
          unit: 'mtr',
          rate: Decimal.parse('500'),
          gstRate: 0,
        ),
      ],
    ));
    await sales.save(SalesDraft(
      id: 'exp-wop',
      number: 'EXP-2',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 4, 9),
      partyName: 'Meridian Exports Ltd',
      partyGstin: '36AABCK1234M1Z5',
      placeOfSupply: '36',
      isInterState: true,
      isExport: true,
      exportType: 'wop',
      lines: [
        SalesLineDraft(
          id: 'exp-wop-line',
          name: 'Cotton fabric',
          hsn: '5208',
          quantity: Decimal.fromInt(4),
          unit: 'mtr',
          rate: Decimal.parse('500'),
          gstRate: 0,
        ),
      ],
    ));

    final report = await GstReturnBuilder(db, firmId)
        .buildGstr1(from: april.from, to: april.to);

    expect(report.expwop, hasLength(1));
    expect(report.expwp, hasLength(1));
    // Both zero-rated supplies belong to the registered customer, so neither
    // may also appear in a domestic bucket.
    expect(report.b2b, isEmpty);
    expect(report.b2cl, isEmpty);
    expect(report.b2cs, isEmpty);

    final wpRow = report.expwp.single.invoices.single;
    expect(wpRow.inum, 'EXP-1');
    expect(wpRow.invoiceType, 'SEWP');
    expect(report.expwop.single.invoices.single.invoiceType, 'SEWOP');

    final json = report.toJson();
    final expwp = (json['expwp'] as List).single as Map<String, dynamic>;
    expect(expwp['pos'], '96', reason: 'exports are supplied outside India');
    expect(((expwp['inv'] as List).single as Map)['inum'], 'EXP-1');
    expect(json['expwop'], isNotEmpty);

    // GSTR-3B has always reported them, as zero-rated supply.
    final three = await buildGstr3b(db, firmId, from: april.from, to: april.to);
    expect(three.zeroRated, Decimal.parse('7000.00'));
  });

  test('HSN rows are rate-wise, carry rt, and never a negative qty',
      () async {
    final sales = db.salesRepositoryFor(firmId);
    await sales.save(SalesDraft(
      id: 'hsn-5',
      number: 'INV-H1',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 4, 10),
      lines: [
        SalesLineDraft(
          id: 'hsn-5-line',
          name: 'Widget',
          hsn: '9987',
          quantity: Decimal.fromInt(10),
          unit: 'pcs',
          rate: Decimal.parse('1000'),
          gstRate: 5,
        ),
      ],
    ));
    await sales.save(SalesDraft(
      id: 'hsn-18',
      number: 'INV-H2',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 4, 11),
      lines: [
        SalesLineDraft(
          id: 'hsn-18-line',
          name: 'Widget',
          hsn: '9987',
          quantity: Decimal.fromInt(2),
          unit: 'pcs',
          rate: Decimal.parse('1000'),
          gstRate: 18,
        ),
      ],
    ));
    // A credit note against the 18% line: the note's effect has to live in the
    // value columns, because Table 12 rejects a negative quantity.
    await sales.save(SalesDraft(
      id: 'hsn-cn',
      number: 'CN-H1',
      docType: 'credit_note',
      invoiceDate: DateTime(2026, 4, 12),
      lines: [
        SalesLineDraft(
          id: 'hsn-cn-line',
          name: 'Widget',
          hsn: '9987',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('1000'),
          gstRate: 18,
        ),
      ],
    ));

    final report = await GstReturnBuilder(db, firmId)
        .buildGstr1(from: april.from, to: april.to);
    final rows = report.hsn.where((h) => h.hsn == '9987').toList();
    expect(rows, hasLength(2),
        reason: 'the same HSN at two rates is two rows, not one');
    expect(rows.map((r) => r.rate).toList()..sort(), [5.0, 18.0]);

    final eighteen = rows.firstWhere((r) => r.rate == 18);
    // 2 sold, 1 returned: 1 net, and never a negative figure.
    expect(eighteen.quantity, Decimal.parse('1.00'));
    expect(eighteen.taxableValue, Decimal.parse('1000.00'));
    expect(eighteen.cgst, Decimal.parse('90.00'));

    final five = rows.firstWhere((r) => r.rate == 5);
    expect(five.quantity, Decimal.parse('10.00'));
    expect(five.taxableValue, Decimal.parse('10000.00'));

    final data = ((report.toJson()['hsn'] as Map)['data'] as List)
        .cast<Map<String, dynamic>>();
    expect(data.map((d) => d['rt']).toList(), containsAll([5, 18]));
    expect(data.every((d) => (d['qty'] as num) >= 0), isTrue);
  });

  test('a debit note beyond the bills reverses ITC instead of vanishing',
      () async {
    final supplier = await db.partyRepositoryFor(firmId).create(
      name: 'Registered Supplier',
      type: 'supplier',
      gstin: '36SUPPL1234T1Z2',
    );
    await db.purchaseRepositoryFor(firmId).save(PurchaseDraft(
      id: 'dn-1',
      number: 'DN-1',
      docType: 'debit_note',
      partyId: supplier.id,
      partyName: supplier.name,
      partyGstin: '36SUPPL1234T1Z2',
      billDate: DateTime(2026, 4, 14),
      lines: [
        PurchaseLineDraft(
          id: 'dn-line',
          name: 'Returned goods',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('5000'),
          gstRate: 18,
        ),
      ],
    ));

    final report =
        await buildGstr3b(db, firmId, from: april.from, to: april.to);

    // There is no bill to claw credit from, so 4(A)(5) cannot be negative —
    // the reversal has to show up in 4(B)(1) or the return over-claims credit.
    expect(report.itcAllOther, Decimal.zero);
    expect(report.itcReversedRule4243, Decimal.parse('900.00'));
    expect(report.itcReversed, Decimal.parse('900.00'));
    expect(report.netItc, Decimal.parse('-900.00'));
    // The consequence of keeping the reversal rather than discarding it: the
    // excess comes back as a cash liability in this period instead of
    // evaporating. That is what Rules 42/43 do to unused credit.
    expect(report.netPayable, Decimal.parse('900.00'));
    final fourB = ((report.toJson()['4'] as Map)['b_reversed'] as Map);
    expect(fourB['rule_42_43'], 900.0);
  });

  test('the reports card nets credit/debit notes and never shows a negative',
      () async {
    final sales = db.salesRepositoryFor(firmId);
    final supplier = await db.partyRepositoryFor(firmId).create(
      name: 'Registered Supplier',
      type: 'supplier',
      gstin: '36SUPPL1234T1Z2',
    );
    // ₹10,000 of taxable sales with ₹1,800 of output tax.
    await sales.save(SalesDraft(
      id: 'agree-inv',
      number: 'INV-1',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 4, 5),
      placeOfSupply: '36',
      lines: [
        SalesLineDraft(
          id: 'agree-line',
          name: 'Consulting',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('10000'),
          gstRate: 18,
        ),
      ],
    ));
    // A credit note for the whole of it, and a bill/debit note pair that nets
    // to a large input credit — net payable must floor at zero, not go below.
    await sales.save(SalesDraft(
      id: 'agree-cn',
      number: 'CN-1',
      docType: 'credit_note',
      invoiceDate: DateTime(2026, 4, 6),
      placeOfSupply: '36',
      lines: [
        SalesLineDraft(
          id: 'agree-cn-line',
          name: 'Consulting',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('10000'),
          gstRate: 18,
        ),
      ],
    ));
    await db.purchaseRepositoryFor(firmId).save(PurchaseDraft(
      id: 'agree-bill',
      number: 'BILL-1',
      docType: 'bill',
      partyId: supplier.id,
      partyName: supplier.name,
      partyGstin: '36SUPPL1234T1Z2',
      billDate: DateTime(2026, 4, 7),
      placeOfSupply: '36',
      lines: [
        PurchaseLineDraft(
          id: 'agree-bill-line',
          name: 'Goods',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('50000'),
          gstRate: 18,
        ),
      ],
    ));

    final repo = db.reportRepositoryFor(firmId);
    final summary = await repo.gstSummary(from: april.from, to: april.to);
    // The credit note cancels the invoice's output tax; the bill's credit
    // stands. Both used to be ignored (invoices/bills only).
    expect(summary.outputTax, Decimal.zero);
    expect(summary.inputTax, Decimal.parse('9000.00'));
    expect(summary.netPayable, Decimal.zero,
        reason: 'a return never declares a negative liability');

    final three = await buildGstr3b(db, firmId, from: april.from, to: april.to);
    expect(three.netPayable, summary.netPayable,
        reason: 'the dashboard KPI and the filed return must agree');

    // A purchase debit note reduces credit by the same rule.
    await db.purchaseRepositoryFor(firmId).save(PurchaseDraft(
      id: 'agree-dn',
      number: 'DN-1',
      docType: 'debit_note',
      partyId: supplier.id,
      partyName: supplier.name,
      partyGstin: '36SUPPL1234T1Z2',
      billDate: DateTime(2026, 4, 9),
      lines: [
        PurchaseLineDraft(
          id: 'agree-dn-line',
          name: 'Returned goods',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('20000'),
          gstRate: 18,
        ),
      ],
    ));
    final after = await repo.gstSummary(from: april.from, to: april.to);
    expect(after.inputTax, Decimal.parse('5400.00'),
        reason: 'the debit note reverses ₹3,600 of the bill credit');
  });
}