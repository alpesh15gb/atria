import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/reports/sources/gst/gstr2_purchase.dart';
import 'package:atria/core/reports/gstr2_purchase_export.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('purchase-derived GSTR2 preserves supplier reference and tax and builds Vyapar-style sections', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    addTearDown(db.close);
    final firm = (await db.firmRepository.create(name: 'Apex')).id;
    await db
        .purchaseRepositoryFor(firm)
        .save(
          PurchaseDraft(
            id: 'p',
            number: 'B1',
            supplierInvoiceNumber: 'MC2025-26/7164',
            partyName: 'Mahaveer Computers',
            docType: 'bill',
            billDate: DateTime(2026, 3, 27),
            lines: [
              PurchaseLineDraft(
                id: 'l',
                name: 'Screen',
                hsn: '85286900',
                quantity: Decimal.one,
                unit: 'pcs',
                rate: Decimal.parse('1000'),
                gstRate: 18,
              ),
            ],
          ),
        );
    final result = await gstr2Purchase.run(
      db,
      firm,
      ReportWindow(
        preset: ReportWindowPreset.custom,
        from: DateTime(2026, 1),
        to: DateTime(2026, 10, 31, 23, 59, 59),
      ),
    );
    expect(result.count, 1);
    expect(result.groups.single.rows.single.cells['number'], 'MC2025-26/7164');
    final dir = await Directory.systemTemp.createTemp('gstr2-');
    addTearDown(() => dir.delete(recursive: true));
    final file = await Gstr2PurchaseExport().write(result, dir);
    final book = Excel.decodeBytes(await file.readAsBytes());
    expect(
      book.tables.keys,
      containsAll([
        'GSTR2 Report',
        'b2b',
        'b2bur',
        'imps',
        'impg',
        'cdnr',
        'cdnur',
        'at',
        'atadj',
        'exemp',
        'itcr',
        'hsnsum',
        'itemSummary',
      ]),
    );
    expect(book['b2bur'].rows.last[1]!.value.toString(), 'MC2025-26/7164');
    expect(book['hsnsum'].rows.last[5]!.value.toString(), '1000');
  });
}
