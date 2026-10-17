import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/reports/gstr2a_import.dart';
import 'package:atria/core/reports/gst_return_builder.dart';
import 'package:atria/core/reports/gst_export_service.dart';
import 'package:atria/core/reports/sources/gst/gstr2a_reconciliation.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late String firmId;
  late Directory exports;
  final month = DateTime(2026, 4, 1);
  final end = DateTime(2026, 4, 30, 23, 59, 59);
  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firmId = (await db.firmRepository.create(
      name: 'GST audit',
      stateCode: '36',
      gstin: '36CZFPM0045M2Z7',
    )).id;
    exports = await Directory.systemTemp.createTemp('gst-format-audit-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => exports.path,
        );
  });
  tearDown(() async {
    await db.close();
    await exports.delete(recursive: true);
  });

  test(
    'QRMP uses all three months and the quarter ending return period',
    () async {
      for (var m = 4; m <= 7; m++) {
        await db
            .salesRepositoryFor(firmId)
            .save(
              SalesDraft(
                id: 'quarter-$m',
                number: 'Q-$m',
                docType: 'invoice',
                invoiceDate: DateTime(2026, m, 5),
                lines: [
                  SalesLineDraft(
                    id: 'ql-$m',
                    name: 'Camera',
                    quantity: Decimal.one,
                    unit: 'pcs',
                    rate: Decimal.parse('100'),
                    gstRate: 18,
                  ),
                ],
              ),
            );
      }
      final start = DateTime(2026, 4);
      final finish = DateTime(2026, 6, 30, 23, 59, 59);
      final one = await GstReturnBuilder(
        db,
        firmId,
      ).buildGstr1(from: start, to: finish);
      final three = await buildGstr3b(db, firmId, from: start, to: finish);
      expect(one.fp, '062026');
      expect(three.fp, '062026');
      expect(
        one.b2cs.fold<double>(
          0,
          (sum, row) => sum + row.taxableValue.toDouble(),
        ),
        300,
      );
    },
  );

  test(
    'B2CL uses invoice value and changes threshold from August 2024',
    () async {
      for (final date in [
        DateTime(2024, 7, 5),
        DateTime(2024, 8, 5),
        DateTime(2026, 4, 5),
      ]) {
        await db
            .salesRepositoryFor(firmId)
            .save(
              SalesDraft(
                id: 's-${date.year}-${date.month}',
                number: 'S-${date.year}-${date.month}',
                docType: 'invoice',
                invoiceDate: date,
                isInterState: true,
                placeOfSupply: '29',
                lines: [
                  SalesLineDraft(
                    id: 'l-${date.year}-${date.month}',
                    name: 'Camera',
                    hsn: '8525',
                    quantity: Decimal.one,
                    unit: 'pcs',
                    rate: Decimal.parse('90000'),
                    gstRate: 18,
                  ),
                ],
              ),
            );
        final report = await GstReturnBuilder(db, firmId).buildGstr1(
          from: DateTime(date.year, date.month),
          to: DateTime(date.year, date.month + 1, 0, 23, 59, 59),
        );
        expect(report.b2cl.length, date.month == 7 ? 0 : 1);
        expect(report.b2cs.length, date.month == 7 ? 1 : 0);
      }
    },
  );

  test('purchase tax heads survive 3B JSON and workbook export', () async {
    await db
        .purchaseRepositoryFor(firmId)
        .save(
          PurchaseDraft(
            id: 'p1',
            number: 'B-1',
            docType: 'bill',
            billDate: DateTime(2026, 4, 5),
            supplierInvoiceNumber: 'V-1',
            partyGstin: '36AABCK1234M1Z5',
            isInterState: false,
            placeOfSupply: '36',
            lines: [
              PurchaseLineDraft(
                id: 'pl',
                name: 'Camera',
                quantity: Decimal.one,
                unit: 'pcs',
                rate: Decimal.parse('1000'),
                gstRate: 18,
              ),
            ],
          ),
        );
    final report = await buildGstr3b(db, firmId, from: month, to: end);
    final json = report.toPortalJson('36CZFPM0045M2Z7');
    final itc = (json['itc_elg'] as Map)['itc_avl'] as List;
    final other = itc.singleWhere((row) => row['ty'] == 'OTH');
    expect(other['iamt'], 0);
    expect(other['camt'], 90);
    expect(other['samt'], 90);
    expect(json['ret_period'], '042026');
    final dir = await GstExportService().exportGstr3b(
      report,
      gstin: '36CZFPM0045M2Z7',
    );
    final workbook = Excel.decodeBytes(
      await File('${dir.path}/gstr3b_042026.xlsx').readAsBytes(),
    );
    expect(
      workbook.tables.keys,
      containsAll([
        '3.1 Report',
        '3.2 Report',
        '4 Report',
        '5 Report',
      ]),
    );
    final output = jsonDecode(
      await File('${dir.path}/gstr3b_042026.json').readAsString(),
    );
    expect(output['itc_elg']['itc_avl'], itc);
  });

  test(
    'portal JSON ZIP persists and rejects another GSTIN or period',
    () async {
      final payload = {'gstin': '36CZFPM0045M2Z7', 'fp': '042026', 'b2b': []};
      final bytes = utf8.encode(jsonEncode(payload));
      final zip = ZipEncoder().encode(
        Archive()..addFile(ArchiveFile('part.json', bytes.length, bytes)),
      )!;
      final decoded = decodeGstr2a(zip);
      await storeImportedGstr2a(db, firmId, month, decoded);
      final stored = await readImportedGstr2a(
        db,
        firmId,
        ReportWindow(preset: ReportWindowPreset.custom, from: month, to: end),
      );
      expect(stored, decoded);
      for (final invalid in [
        {...decoded, 'gstin': '29CZFPM0045M2Z7'},
        {...decoded, 'fp': '052026'},
      ]) {
        await expectLater(
          Gstr2aReconciliation.fromPortalJson(
            invalid,
            db: db,
            firmId: firmId,
            from: month,
            to: end,
            firmGstin: '36CZFPM0045M2Z7',
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('Excel detail rows group multiple rates into one supplier invoice', () {
    final book = Excel.createExcel();
    final sheet = book['B2B'];
    sheet.appendRow([
      for (final h in [
        'GSTIN of Supplier',
        'Invoice Number',
        'Invoice Date',
        'Taxable Value',
        'Integrated Tax',
        'Central Tax',
        'State/UT Tax',
        'Cess',
      ])
        TextCellValue(h),
    ]);
    for (final taxable in [1000, 2000]) {
      sheet.appendRow([
        TextCellValue('36AABCK1234M1Z5'),
        TextCellValue('V-1'),
        TextCellValue('05-04-2026'),
        IntCellValue(taxable),
        IntCellValue(0),
        IntCellValue(90),
        IntCellValue(90),
        IntCellValue(0),
      ]);
    }
    final parsed = decodeGstr2a(book.encode()!);
    final suppliers = parsed['b2b'] as List;
    expect(suppliers, hasLength(1));
    expect(suppliers.single['inv'], hasLength(1));
    expect(suppliers.single['inv'][0]['itms'], hasLength(2));
  });

  test(
    'supplier credit notes reduce portal tax instead of disappearing',
    () async {
      final statement = decodeGstr2a(
        utf8.encode(
          jsonEncode({
            'cdn': [
              {
                'ctin': '36AABCK1234M1Z5',
                'nt': [
                  {
                    'nt_num': 'CN-1',
                    'nt_dt': '05-04-2026',
                    'ntty': 'C',
                    'val': 1180,
                    'itms': [
                      {
                        'itm_det': {'txval': 1000, 'camt': 90, 'samt': 90},
                      },
                    ],
                  },
                ],
              },
            ],
          }),
        ),
      );
      final rec = await Gstr2aReconciliation.fromPortalJson(
        statement,
        db: db,
        firmId: firmId,
        from: month,
        to: end,
      );
      expect(rec.portalTotalTax, -180);
      expect(rec.rows.single.portalTaxable, -1000);
      expect(rec.rows.single.supplierGstin, '36AABCK1234M1Z5');
    },
  );
}
