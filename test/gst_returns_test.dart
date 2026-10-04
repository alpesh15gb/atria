import 'dart:convert';
import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/reports/gst_export_service.dart';
import 'package:atria/core/reports/gst_return_builder.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cover for the GST return pipeline: GSTR-1 tables (B2B/B2CS/HSN/doc-issue),
/// the portal JSON shape (v1.1: fp=MMYYYY, idt=DD-MM-YYYY, rchrg/inv_typ),
/// GSTR-3B tables 3.1/3.2/4/5, and GSTR-2A import + reconciliation.
void main() {
  late AppDatabase db;
  late String firmId;
  late FirmEntity firm;
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('atria_gst_test');
    // path_provider in tests: route getApplicationDocumentsDirectory() at the
    // temp dir so exports land somewhere disposable.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDownAll(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firm = await db.firmRepository.create(
      name: 'Apex Integrations',
      stateCode: '36',
      gstin: '36CZFPM0045M2Z7',
    );
    firmId = firm.id;
  });

  tearDown(() => db.close());

  test('GSTR-1 B2B: intra-state invoice splits CGST/SGST in portal JSON',
      () async {
    final parties = db.partyRepositoryFor(firmId);
    final customer = await parties.create(
      name: 'Keystone Infra',
      type: 'customer',
      gstin: '36AABCK1234M1Z5',
    );
    final sales = db.salesRepositoryFor(firmId);
    await sales.save(SalesDraft(
      id: 'inv1',
      number: 'INV-1',
      docType: 'invoice',
      partyId: customer.id,
      partyName: customer.name,
      partyGstin: '36AABCK1234M1Z5',
      invoiceDate: DateTime(2026, 4, 5),
      placeOfSupply: '36',
      isInterState: false,
      lines: [
        SalesLineDraft(
          id: 'l1',
          name: 'Annual Maintenance Contract',
          hsn: '998713',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('1129'),
          gstRate: 18,
        ),
      ],
    ));

    final report = await GstReturnBuilder(db, firmId).buildGstr1(
      from: DateTime(2026, 4, 1),
      to: DateTime(2026, 4, 30, 23, 59, 59),
    );

    expect(report.fp, '042026');
    expect(report.firmGstin, '36CZFPM0045M2Z7');
    expect(report.b2b, hasLength(1));
    expect(report.b2b.first.ctin, '36AABCK1234M1Z5');
    final inv = report.b2b.first.invoices.single;
    expect(inv.inum, 'INV-1');
    expect(inv.idt, '05-04-2026', reason: 'portal dates are DD-MM-YYYY');
    final det = inv.itms.single;
    expect(det.taxableValue, Decimal.parse('1129.00'));
    expect(det.cgst, Decimal.parse('101.61'));
    expect(det.sgst, Decimal.parse('101.61'));
    expect(det.igst, Decimal.zero);

    // The JSON the offline tool expects.
    final json = report.toJson();
    expect(json['fp'], '042026');
    expect(json['gstin'], '36CZFPM0045M2Z7');
    final b2b = (json['b2b'] as List).single as Map<String, dynamic>;
    expect(b2b['ctin'], '36AABCK1234M1Z5');
    final invJson = (b2b['inv'] as List).single as Map<String, dynamic>;
    expect(invJson['rchrg'], 'N');
    expect(invJson['inv_typ'], 'R');
    final itms = (invJson['itms'] as List).single as Map<String, dynamic>;
    final detJson = itms['itm_det'] as Map<String, dynamic>;
    expect(detJson['rt'], 18);
    expect(detJson['camt'], 101.61);
    expect(detJson['samt'], 101.61);
    expect(detJson['iamt'], 0);
    expect((json['hsn'] as Map)['data'], isNotEmpty);
    expect((json['doc_issue'] as Map)['doc_det'], isNotEmpty);
  });

  test('GSTR-3B: 3.1(a) aggregates output tax, 4(A5) sums registered ITC',
      () async {
    final parties = db.partyRepositoryFor(firmId);
    final customer = await parties.create(
        name: 'Local Buyer', type: 'customer', gstin: '36LOCALB1234R1Z9');
    final supplier = await parties.create(
        name: 'Registered Supplier', type: 'supplier', gstin: '36SUPPL1234T1Z2');
    final sales = db.salesRepositoryFor(firmId);
    final purchases = db.purchaseRepositoryFor(firmId);

    await sales.save(SalesDraft(
      id: 's1',
      number: 'INV-1',
      docType: 'invoice',
      partyId: customer.id,
      partyName: customer.name,
      partyGstin: '36LOCALB1234R1Z9',
      invoiceDate: DateTime(2026, 5, 2),
      placeOfSupply: '36',
      isInterState: false,
      lines: [
        SalesLineDraft(
          id: 'sl',
          name: 'Consulting',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('10000'),
          gstRate: 18,
        ),
      ],
    ));
    await purchases.save(PurchaseDraft(
      id: 'p1',
      number: 'BILL-1',
      docType: 'bill',
      partyId: supplier.id,
      partyName: supplier.name,
      partyGstin: '36SUPPL1234T1Z2',
      billDate: DateTime(2026, 5, 3),
      placeOfSupply: '36',
      isInterState: false,
      lines: [
        PurchaseLineDraft(
          id: 'pl',
          name: 'Office supplies',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('5000'),
          gstRate: 18,
        ),
      ],
    ));

    final report = await buildGstr3b(
      db,
      firmId,
      from: DateTime(2026, 5, 1),
      to: DateTime(2026, 5, 31, 23, 59, 59),
    );

    expect(report.fp, '052026');
    expect(report.outwardTaxable, Decimal.parse('10000.00'));
    expect(report.outwardCgst, Decimal.parse('900.00'));
    expect(report.outwardSgst, Decimal.parse('900.00'));
    expect(report.itcAllOther, Decimal.parse('900.00'));
    // Net payable = output (1800) − ITC (900).
    expect(report.netPayable, Decimal.parse('900.00'));

    final json = report.toJson();
    expect((json['3.1'] as Map)['a_outward_taxable'], isNotNull);
    expect((json['4'] as Map)['a_available'], isNotNull);
  });

  test('GST paid on an expense is claimed as 4(A5) credit', () async {
    await db.salesRepositoryFor(firmId).save(SalesDraft(
      id: 's-exp',
      number: 'INV-9',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 5, 2),
      lines: [
        SalesLineDraft(
          id: 'sl-exp',
          name: 'Consulting',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('10000'),
          gstRate: 18,
        ),
      ],
    ));
    // A rent bill the firm paid itself: ₹10,000 + ₹1,800 GST, recorded as an
    // expense rather than as a purchase because there is nothing to resell.
    await db.expenseRepositoryFor(firmId).create(
          type: 'expense',
          number: 'EXP-1',
          category: 'rent',
          amount: 11800,
          date: DateTime(2026, 5, 5),
          mode: 'bank_transfer',
          gstAmount: 1800,
        );

    final from = DateTime(2026, 5, 1);
    final to = DateTime(2026, 5, 31, 23, 59, 59);
    final report = await buildGstr3b(db, firmId, from: from, to: to);
    expect(report.itcAllOther, Decimal.parse('1800.00'));
    // Output 900 + 900, credit 1800: nothing to pay.
    expect(report.netPayable, Decimal.zero);

    // The reports screen reads GstSummary rather than the 3B, and used to show
    // the full ₹1,800 as payable because it never looked at expenses.
    final summary =
        await db.reportRepositoryFor(firmId).gstSummary(from: from, to: to);
    expect(summary.inputFromExpenses, Decimal.parse('1800.00'));
    expect(summary.netPayable, Decimal.zero);
    // Only the taxable part of the expense is a cost, which is why claiming
    // the credit does not change the P&L.
    expect(
      await db.ledgerRepositoryFor(firmId).inputTaxFromExpenses(to: to),
      1800,
    );
  });

  test('the fiscal-year summary is one row per month plus a totals row',
      () async {
    final sales = db.salesRepositoryFor(firmId);
    await sales.save(SalesDraft(
      id: 'fy-may',
      number: 'INV-FY-MAY',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 5, 12),
      lines: [
        SalesLineDraft(
          id: 'fy-line-may',
          name: 'Consulting',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('1000'),
          gstRate: 18,
        ),
      ],
    ));
    await sales.save(SalesDraft(
      id: 'fy-jun',
      number: 'INV-FY-JUN',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 6, 3),
      lines: [
        SalesLineDraft(
          id: 'fy-line-jun',
          name: 'Consulting',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('2000'),
          gstRate: 18,
        ),
      ],
    ));

    // The screen walks each month of the fiscal year and builds one row from
    // that month's 3B; the export just lays the rows out.
    final rows = <FiscalYearGstRow>[];
    var cursor = DateTime(2026, 4, 1);
    while (!cursor.isAfter(DateTime(2026, 6, 1))) {
      final report = await buildGstr3b(
        db,
        firmId,
        from: cursor,
        to: DateTime(cursor.year, cursor.month + 1, 0, 23, 59, 59),
      );
      rows.add(FiscalYearGstRow(
        period: '${cursor.month.toString().padLeft(2, '0')}-${cursor.year}',
        taxable: report.outwardTaxable,
        igst: report.outwardIgst,
        cgst: report.outwardCgst,
        sgst: report.outwardSgst,
        cess: report.outwardCess,
        itc: report.netItc,
        netPayable: report.netPayable,
        zeroRated: report.zeroRated,
        nilRated: report.nilRated,
      ));
      cursor = DateTime(cursor.year, cursor.month + 1, 1);
    }

    final dir = await GstExportService().exportFiscalYear(
      gstin: '29ABCDE1234F1Z5',
      fyLabel: '2026-27',
      months: rows,
    );
    final file = File('${dir.path}${Platform.pathSeparator}'
        'fy_2026-27_gst_summary.csv');
    expect(file.existsSync(), isTrue);
    // The BOM has to be checked on the bytes: Dart's UTF-8 decoder strips a
    // leading BOM on the way into a String.
    final bytes = await file.readAsBytes();
    expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF],
        reason: 'Excel needs the BOM');
    final csv = await file.readAsString();
    expect(csv, contains('04-2026'));
    expect(csv, contains('05-2026'));
    expect(csv, contains('06-2026'));
    expect(csv, contains('Total'));
    // 1,000 + 2,000 of May and June sales, and their 18% tax.
    expect(csv, contains('"3000.0"'));
    expect(csv, contains('"540.0"'));
  });

  test('the rate-wise table is the same read in one query as one per invoice',
      () async {
    final sales = db.salesRepositoryFor(firmId);
    for (var i = 0; i < 3; i++) {
      await sales.save(SalesDraft(
        id: 'batch-$i',
        number: 'INV-B$i',
        docType: 'invoice',
        invoiceDate: DateTime(2026, 5, 10 + i),
        lines: [
          SalesLineDraft(
            id: 'batch-line-$i',
            name: 'Widget',
            quantity: Decimal.fromInt(2),
            unit: 'pcs',
            rate: Decimal.fromInt(1000),
            gstRate: 12,
          ),
        ],
      ));
    }

    final start = DateTime(2026, 5, 1);
    final end = DateTime(2026, 5, 31, 23, 59, 59);
    final documents = await sales.list(
        docType: 'invoice', from: start, to: end, limit: 1000000);

    // The batched read has to agree with the per-document one, because the
    // summary switched to it purely for speed.
    final batched = await sales
        .itemsForMany(documents.map((d) => d.id).toList());
    for (final doc in documents) {
      final single = await sales.itemsFor(doc.id);
      expect(batched[doc.id]!.map((l) => l.id).toList(),
          single.map((l) => l.id).toList());
    }
    expect(await sales.itemsForMany(const []), isEmpty);

    final summary =
        await db.reportRepositoryFor(firmId).gstSummary(from: start, to: end);
    final twelve = summary.outwardByRate
        .where((r) => r.rate == 12)
        .toList();
    expect(twelve.length, 1);
    expect(twelve.first.lineCount, 3);
    expect(twelve.first.taxableValue, Decimal.parse('6000.00'));
  });

  test('GSTR-1 JSON round-trips through the export service to disk',
      () async {
    final report = await GstReturnBuilder(db, firmId).buildGstr1(
      from: DateTime(2026, 4, 1),
      to: DateTime(2026, 4, 30, 23, 59, 59),
    );
    final dir = await GstExportService().exportGstr1(report);
    final jsonFile = File(
        '${dir.path}${Platform.pathSeparator}'
        'gstr1_${report.firmGstin}_${report.fp}.json');
    expect(jsonFile.existsSync(), isTrue);
    final parsed = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
    expect(parsed['gstin'], report.firmGstin);
    final csv = File(
        '${dir.path}${Platform.pathSeparator}gstr1_b2b.csv');
    expect(csv.existsSync(), isTrue);
  });

  test('GSTR-2A reconciliation: matched, books_only, portal_only', () async {
    final parties = db.partyRepositoryFor(firmId);
    final supplier = await parties.create(
        name: 'GST Supplier', type: 'supplier', gstin: '36SUPPL1234T1Z2');
    final purchases = db.purchaseRepositoryFor(firmId);

    // A bill that will match, and one the supplier never filed.
    await purchases.save(PurchaseDraft(
      id: 'pb1',
      number: 'BILL-100',
      docType: 'bill',
      partyId: supplier.id,
      partyName: supplier.name,
      partyGstin: '36SUPPL1234T1Z2',
      billDate: DateTime(2026, 6, 2),
      placeOfSupply: '36',
      isInterState: false,
      lines: [
        PurchaseLineDraft(
          id: 'x',
          name: 'Goods',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('1000'),
          gstRate: 18,
        ),
      ],
    ));
    await purchases.save(PurchaseDraft(
      id: 'pb2',
      number: 'BILL-101',
      docType: 'bill',
      partyId: supplier.id,
      partyName: supplier.name,
      partyGstin: '36SUPPL1234T1Z2',
      billDate: DateTime(2026, 6, 3),
      placeOfSupply: '36',
      isInterState: false,
      lines: [
        PurchaseLineDraft(
          id: 'y',
          name: 'Goods 2',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('500'),
          gstRate: 18,
        ),
      ],
    ));

    final portalJson = {
      'b2b': [
        {
          'ctin': '36SUPPL1234T1Z2',
          'trdnm': 'GST Supplier',
          'inv': [
            {
              'inum': 'BILL-100',
              'idt': '02-06-2026',
              'val': 1180.0,
              'itms': [
                {
                  'num': 1,
                  'itm_det': {
                    'rt': 18,
                    'txval': 1000.0,
                    'camt': 90.0,
                    'samt': 90.0,
                    'iamt': 0,
                    'csamt': 0,
                  },
                },
              ],
            },
            {
              // Filed by the supplier but missing from the books.
              'inum': 'BILL-999',
              'idt': '10-06-2026',
              'val': 236.0,
              'itms': [
                {
                  'num': 1,
                  'itm_det': {
                    'rt': 18,
                    'txval': 200.0,
                    'camt': 18.0,
                    'samt': 18.0,
                    'iamt': 0,
                    'csamt': 0,
                  },
                },
              ],
            },
          ],
        },
      ],
    };

    final rec = await Gstr2aReconciliation.fromPortalJson(
      portalJson,
      db: db,
      firmId: firmId,
      from: DateTime(2026, 6, 1),
      to: DateTime(2026, 6, 30, 23, 59, 59),
    );

    expect(rec.matched, 1);
    expect(rec.portalOnly, 1, reason: 'BILL-999 was never recorded');
    expect(rec.booksOnly, 1, reason: 'BILL-101 was never filed');
    expect(rec.rows, hasLength(3));
  });

  test('GSTR-1 CDNUR includes line items with non-zero GST rates and amounts',
      () async {
    final sales = db.salesRepositoryFor(firmId);
    await sales.save(SalesDraft(
      id: 'cn-unreg-1',
      number: 'CN-101',
      docType: 'credit_note',
      invoiceDate: DateTime(2026, 5, 10),
      partyName: 'Unregistered Walkin',
      partyGstin: '',
      lines: [
        SalesLineDraft(
          id: 'cn-l1',
          name: 'Returned Item',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('1000'),
          gstRate: 18,
        ),
      ],
    ));

    final builder = GstReturnBuilder(db, firmId);
    final report = await builder.buildGstr1(
      from: DateTime(2026, 5, 1),
      to: DateTime(2026, 5, 31, 23, 59, 59),
    );

    expect(report.cdnur, hasLength(1));
    final note = report.cdnur.first;
    expect(note.ntNum, 'CN-101');
    expect(note.rate, 18.0);
    expect(note.taxableValue, Decimal.parse('1000.00'));
    expect(note.itms, hasLength(1));
    expect(note.itms.first.rate, 18.0);
    expect(note.itms.first.cgst, Decimal.parse('90.00'));
    expect(note.itms.first.sgst, Decimal.parse('90.00'));

    final json = note.toJson();
    final itmsJson = json['itms'] as List;
    expect(itmsJson, hasLength(1));
    final itemDet = (itmsJson.first as Map)['itm_det'] as Map;
    expect(itemDet['rt'], 18.0);
    expect(itemDet['txval'], 1000.0);
  });

  test('GSTR-3B net payable requires cash payment for reverse charge liabilities',
      () async {
    // Record inward supply liable to reverse charge (₹10,000 @ 18% = ₹1,800 RCM tax)
    await db.purchaseRepositoryFor(firmId).save(PurchaseDraft(
      id: 'p-rcm-1',
      number: 'BILL-RCM',
      docType: 'bill',
      billDate: DateTime(2026, 5, 15),
      partyName: 'Transporter',
      partyGstin: '',
      reverseCharge: true,
      lines: [
        PurchaseLineDraft(
          id: 'pl-rcm-1',
          name: 'Freight charges',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('10000'),
          gstRate: 18,
        ),
      ],
    ));

    final report = await buildGstr3b(
      db,
      firmId,
      from: DateTime(2026, 5, 1),
      to: DateTime(2026, 5, 31, 23, 59, 59),
    );

    // Even with zero outward supplies, reverse charge tax must be paid in cash
    expect(report.reverseChargeTax, Decimal.parse('1800.00'));
    expect(report.netPayable, Decimal.parse('1800.00'));
  });
}
