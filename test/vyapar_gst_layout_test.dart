import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/reports/gst_return_builder.dart';
import 'package:atria/core/reports/sources/gst/gstr2_purchase.dart';
import 'package:atria/core/reports/vyapar_gst_workbook.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String? value(Excel book, String sheet, String cell) =>
    book[sheet].cell(CellIndex.indexByString(cell)).value?.toString();
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('mixed invoice series stay separate in documents issued and grouped in JSON', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    addTearDown(db.close);
    final firm = (await db.firmRepository.create(
      name: 'Books',
      gstin: '36CZFPM0045M2Z7',
      stateCode: '36',
    )).id;
    for (final number in ['1', '5', '2026-27/1', '2026-27/9']) {
      await db
          .salesRepositoryFor(firm)
          .save(
            SalesDraft(
              id: number,
              number: number,
              docType: 'invoice',
              invoiceDate: DateTime(2026, 4, 5),
              lines: [
                SalesLineDraft(
                  id: 'l$number',
                  name: 'Camera',
                  quantity: Decimal.one,
                  unit: 'pcs',
                  rate: Decimal.fromInt(100),
                  gstRate: 18,
                ),
              ],
            ),
          );
    }
    final report = await GstReturnBuilder(
      db,
      firm,
    ).buildGstr1(from: DateTime(2026, 4), to: DateTime(2026, 4, 30));
    expect(report.docIssue, hasLength(2));
    expect(report.docIssue.map((r) => r.total), everyElement(2));
    final groups = (report.toJson()['doc_issue'] as Map)['doc_det'] as List;
    expect(groups, hasLength(1));
    expect(groups.single['docs'], hasLength(2));
  });
  test('all reference labels, tab order, widths and font size survive Excel serialization', () async {
    final layouts =
        jsonDecode(await rootBundle.loadString(VyaparGstWorkbook.asset)) as Map;
    for (final kind in ['GSTR1', 'GSTR2', 'GSTR3B']) {
      final book = await VyaparGstWorkbook().create(kind);
      final decoded = Excel.decodeBytes(book.encode()!);
      final definitions = layouts[kind] as List;
      expect(
        decoded.tables.keys.toList(),
        definitions.map((s) => s['name']).toList(),
      );
      expect(decoded.tables.keys, isNot(contains('Sheet1')));
      expect(decoded.getDefaultSheet(), definitions.first['name']);
      for (final definition in definitions) {
        final sheet = decoded[definition['name'] as String];
        for (final e in (definition['static'] as Map).entries) {
          final cell = sheet.cell(CellIndex.indexByString(e.key as String));
          expect(
            cell.value.toString(),
            e.value,
            reason: '$kind ${definition['name']} ${e.key}',
          );
          expect(cell.cellStyle!.fontSize, 12);
        }
        for (final e in (definition['widths'] as Map).entries) {
          expect(
            sheet.getColumnWidth(
              CellIndex.indexByString('${e.key}1').columnIndex,
            ),
            closeTo(e.value as num, .01),
          );
        }
      }
    }
  });
  test('populated exports retain reference positions and count multi-rate invoices once', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    addTearDown(db.close);
    final dir = await Directory.systemTemp.createTemp('vyapar-layout-');
    addTearDown(() => dir.delete(recursive: true));
    final firm = (await db.firmRepository.create(
      name: 'New Business',
      gstin: '36CZFPM0045M2Z7',
      stateCode: '36',
    )).id;
    final sales = db.salesRepositoryFor(firm);
    await sales.save(
      SalesDraft(
        id: 'sale',
        number: 'INV-1',
        docType: 'invoice',
        partyName: 'New Customer',
        partyGstin: '36AABCK1234M1Z5',
        placeOfSupply: '36',
        invoiceDate: DateTime(2026, 4, 5),
        lines: [
          SalesLineDraft(
            id: 's1',
            name: 'Camera',
            hsn: '8525',
            quantity: Decimal.one,
            unit: 'pcs',
            rate: Decimal.fromInt(1000),
            gstRate: 18,
          ),
          SalesLineDraft(
            id: 's2',
            name: 'Cable',
            hsn: '8544',
            quantity: Decimal.one,
            unit: 'pcs',
            rate: Decimal.fromInt(1000),
            gstRate: 5,
          ),
        ],
      ),
    );
    await db
        .purchaseRepositoryFor(firm)
        .save(
          PurchaseDraft(
            id: 'buy',
            number: 'B1',
            supplierInvoiceNumber: 'V-1',
            docType: 'bill',
            partyName: 'New Supplier',
            partyGstin: '36AABCK1234M1Z5',
            placeOfSupply: '36',
            billDate: DateTime(2026, 4, 5),
            lines: [
              PurchaseLineDraft(
                id: 'p1',
                name: 'Camera',
                hsn: '8525',
                quantity: Decimal.one,
                unit: 'pcs',
                rate: Decimal.fromInt(1000),
                gstRate: 18,
              ),
              PurchaseLineDraft(
                id: 'p2',
                name: 'Cable',
                hsn: '8544',
                quantity: Decimal.one,
                unit: 'pcs',
                rate: Decimal.fromInt(1000),
                gstRate: 5,
              ),
            ],
          ),
        );
    final from = DateTime(2026, 4), to = DateTime(2026, 4, 30, 23, 59, 59);
    final writer = VyaparGstWorkbook();
    final one = await GstReturnBuilder(db, firm).buildGstr1(from: from, to: to);
    final file1 = await writer.gstr1(one, File('${dir.path}/one.xlsx'));
    final a = Excel.decodeBytes(await file1.readAsBytes());
    expect(a.tables.length, 14);
    expect(value(a, 'GSTR1 Report', 'B4'), 'New Business');
    expect(value(a, 'GSTR1 Report', 'B1'), 'April 2026 - April 2026');
    expect(value(a, 'GSTR1 Report', 'B11'), 'New Customer');
    expect(value(a, 'GSTR1 Report', 'E11'), '05/04/2026');
    expect(value(a, 'GSTR1 Report', 'F13'), '2230');
    expect(value(a, 'b2b,sez,de', 'C3'), '1');
    expect(value(a, 'b2b,sez,de', 'E3'), '2230');
    expect(value(a, 'b2b,sez,de', 'L3'), '2000');
    expect(value(a, 'b2b,sez,de', 'B5'), 'New Customer');
    expect(value(a, 'b2b,sez,de', 'D5'), '05-Apr-2026');
    expect(value(a, 'GSTR1 Report', 'A10'), isNull);
    final two = await gstr2Purchase.run(
      db,
      firm,
      ReportWindow(preset: ReportWindowPreset.custom, from: from, to: to),
    );
    final file2 = await writer.gstr2(
      two,
      File('${dir.path}/two.xlsx'),
      gstin: '36CZFPM0045M2Z7',
      firmName: 'New Business',
    );
    final b = Excel.decodeBytes(await file2.readAsBytes());
    expect(b.tables.length, 13);
    expect(value(b, 'GSTR2 Report', 'F13'), '2230');
    expect(value(b, 'b2b', 'B3'), '1');
    expect(value(b, 'b2b', 'D3'), '2230');
    expect(value(b, 'b2b', 'I3'), '2000');
    expect(value(b, 'GSTR2 Report', 'D11'), 'V-1');
    expect(value(b, 'b2b', 'B5'), 'V-1');
    final three = await buildGstr3b(db, firm, from: from, to: to);
    final file3 = await writer.gstr3b(three, File('${dir.path}/three.xlsx'));
    final c = Excel.decodeBytes(await file3.readAsBytes());
    final layouts =
        jsonDecode(await rootBundle.loadString(VyaparGstWorkbook.asset)) as Map;
    for (final entry in {
      'GSTR1': file1,
      'GSTR2': file2,
      'GSTR3B': file3,
    }.entries) {
      final zip = ZipDecoder().decodeBytes(await entry.value.readAsBytes());
      final definitions = layouts[entry.key] as List;
      for (var i = 0; i < definitions.length; i++) {
        final xmlFile = zip.firstWhere(
          (f) => f.name == 'xl/worksheets/sheet${i + 1}.xml',
        );
        final document = XmlDocument.parse(
          utf8.decode(xmlFile.content as List<int>),
        );
        final widths = definitions[i]['widths'] as Map;
        for (final col in document.findAllElements('col')) {
          final key = CellIndex.indexByColumnRow(
            columnIndex: int.parse(col.getAttribute('min')!) - 1,
            rowIndex: 0,
          ).cellId.replaceAll(RegExp(r'\d'), '');
          if (widths.containsKey(key))
            expect(double.parse(col.getAttribute('width')!), widths[key]);
        }
      }
    }
    expect(c.tables.keys.toList(), [
      '3.1 Report',
      '3.2 Report',
      '4 Report',
      '5 Report',
    ]);
    expect(value(c, '3.1 Report', 'B1'), '04/2026');
    expect(value(c, '3.1 Report', 'B5'), '2000');
    expect(value(c, '3.1 Report', 'D5'), '115');
    expect(value(c, '4 Report', 'C8'), '115');
    for (final book in [a, b, c]) {
      expect(book.tables.keys, isNot(contains('Sheet1')));
      expect(value(book, book.tables.keys.first, 'A1'), isNotNull);
    }
  });
}
