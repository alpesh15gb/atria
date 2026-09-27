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
}
