import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/services/invoice_pdf.dart';
import 'package:atria/core/services/purchase_pdf.dart';
import 'package:atria/core/services/pdf_template_style.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers/document_format_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('render all document formats for visual audit', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    try {
      final (firm, invoice, items, bill, purchaseItems) =
          await documentFormatFixture(db);
      final output = await Directory('build/import-audit/document-formats')
          .create(recursive: true);
      final samples = await Directory('output/pdf').create(recursive: true);
      for (final style in PdfTemplateStyle.all) {
        final chosen = firm.copyWith(pdfTemplate: style.id);
        final bytes = await InvoicePdf.forFirm(chosen)
            .build(invoice: invoice, items: items);
        await File('${output.path}/${style.id}-invoice.pdf')
            .writeAsBytes(bytes);
        await File('${samples.path}/apex-${style.id}-sample.pdf')
            .writeAsBytes(bytes);
        await File('${output.path}/${style.id}-quotation.pdf').writeAsBytes(
          await InvoicePdf.forFirm(chosen).build(
            invoice: invoice.copyWith(docType: 'quotation'),
            items: items,
          ),
        );
        await File('${output.path}/${style.id}-purchase.pdf').writeAsBytes(
          await PurchasePdf.forFirm(chosen)
              .build(bill: bill, items: purchaseItems),
        );
      }
    } finally {
      await db.close();
    }
  });
}
