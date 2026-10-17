import 'dart:convert';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/services/invoice_pdf.dart';
import 'package:atria/core/services/purchase_pdf.dart';
import 'package:atria/core/services/pdf_template_style.dart';
import 'package:atria/core/services/reference_document_pdf.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/document_format_fixture.dart';
import 'helpers/rendered_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('five formats, independent overrides, shared default and legacy compatibility', () {
    expect(PdfTemplateStyle.all.length, 5);
    var choices = const DocumentTemplates()
        .withChoice('default', 'ledger')
        .withChoice('invoice', 'clean')
        .withChoice('quotation', 'business');
    choices = DocumentTemplates.parse(choices.encode());
    expect(choices.forDocument('invoice').id, 'clean');
    expect(choices.forDocument('purchase').id, 'ledger');
    expect(choices.forDocument('quotation').id, 'business');
    choices = choices.withChoice('default', 'detailed');
    expect(choices.forDocument('purchase').id, 'detailed');
    expect(choices.forDocument('invoice').id, 'clean');
    expect(
      choices.withChoice('invoice', null).forDocument('invoice').id,
      'detailed',
    );
    expect(DocumentTemplates.parse('modern').defaultStyle.id, 'modern');
    expect(DocumentTemplates.parse('{broken').defaultStyle.id, 'classic');
    expect(
      DocumentTemplates.parse(
        jsonEncode({
          'default': {'bad': 1},
          'invoice': 12,
        }),
      ).forDocument('invoice').id,
      'classic',
    );
  });
  test(
    'settings persist in the synchronized firm row without changing schema',
    () async {
      final db = AppDatabase.test(NativeDatabase.memory());
      try {
        final firm = await db.firmRepository.create(name: 'Formats');
        final choices = const DocumentTemplates(
          defaultId: 'ledger',
          invoice: 'clean',
          purchase: 'business',
          quotation: 'detailed',
        );
        await db.firmRepository.update(
          firm.copyWith(pdfTemplate: choices.encode()),
        );
        final stored = (await db.firmRepository.getById(firm.id))!;
        expect(
          DocumentTemplates.parse(stored.pdfTemplate).encode(),
          choices.encode(),
        );
        expect(
          (await db.select(db.syncQueue).get()).where(
            (q) => q.entity == 'firms',
          ),
          isNotEmpty,
        );
      } finally {
        await db.close();
      }
    },
  );
  for (final registered in [true, false]) {
    test(
      'all five formats render invoice, purchase and quotation for ${registered ? 'GST' : 'non-GST'} business',
      () async {
        final db = AppDatabase.test(NativeDatabase.memory());
        try {
          final (firm, invoice, items, bill, purchaseItems) =
              await documentFormatFixture(db, registered: registered);
          expect(
            ReferenceDocument.sale(firm, invoice, items).showTax,
            registered,
          );
          for (final style in PdfTemplateStyle.all) {
            final chosen = firm.copyWith(pdfTemplate: style.id);
            for (final bytes in [
              await InvoicePdf.forFirm(chosen)
                  .build(invoice: invoice, items: items),
              await InvoicePdf.forFirm(chosen).build(
                invoice: invoice.copyWith(docType: 'quotation'),
                items: items,
              ),
              await PurchasePdf.forFirm(chosen)
                  .build(bill: bill, items: purchaseItems),
            ]) {
              expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
              expect(bytes.length, greaterThan(1000));
            }
          }
        } finally {
          await db.close();
        }
      },
    );
  }
  test('document overrides reach the real invoice, purchase and quotation builders', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    try {
      final (firm, invoice, items, bill, purchaseItems) =
          await documentFormatFixture(db);
      final chosen = firm.copyWith(
        pdfTemplate: const DocumentTemplates(
          defaultId: 'ledger',
          invoice: 'clean',
          purchase: 'business',
          quotation: 'detailed',
        ).encode(),
      );
      final saleText = await renderedText(
        await InvoicePdf.forFirm(chosen).build(invoice: invoice, items: items),
      );
      final purchaseText = await renderedText(
        await PurchasePdf.forFirm(chosen)
            .build(bill: bill, items: purchaseItems),
      );
      final quoteText = await renderedText(
        await InvoicePdf.forFirm(chosen).build(
          invoice: invoice.copyWith(docType: 'quotation'),
          items: items,
        ),
      );
      expect(saleText, contains('Bill From:'));
      expect(purchaseText, contains('Dispatch From:'));
      expect(quoteText, contains('Quotation #:'));
      expect(quoteText, isNot(contains('Bill From:')));
      expect(
        (await db.salesRepositoryFor(firm.id).getById(invoice.id)),
        invoice,
      );
      expect((await db.purchaseRepositoryFor(firm.id).getById(bill.id)), bill);
    } finally {
      await db.close();
    }
  });
  test('new formats retain settlement and quotation payment rules', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    try {
      final (firm, invoice, items, _, _) = await documentFormatFixture(db);
      for (final style in PdfTemplateStyle.all.where((s) => s.isReference)) {
        final builder = InvoicePdf.forFirm(
          firm.copyWith(pdfTemplate: style.id),
        );
        for (final doc in [
          invoice.copyWith(docType: 'quotation'),
          invoice.copyWith(paidAmount: invoice.grandTotal, balanceDue: 0),
          invoice.copyWith(status: 'cancelled'),
        ]) {
          final printed = await renderedText(
            await builder.build(invoice: doc, items: items),
          );
          expect(printed, isNot(contains('Pay using UPI:')));
          expect(printed, isNot(contains('Bank Details:')));
          if (doc.docType == 'quotation') {
            expect(printed, isNot(contains('Amount Paid')));
          } else if (doc.status == 'cancelled') {
            expect(printed, contains('CANCELLED'));
          } else {
            expect(printed, contains('Amount Paid'));
          }
          expect(printed, isNot(contains('digitally signed')));
        }
      }
    } finally {
      await db.close();
    }
  });
  test(
    'reference formats paginate long documents with repeated item headings',
    () async {
      final db = AppDatabase.test(NativeDatabase.memory());
      try {
        final (firm, invoice, items, bill, purchaseItems) =
            await documentFormatFixture(db, count: 100, interState: true);
        for (final style in PdfTemplateStyle.all.where((s) => s.isReference)) {
          final chosen = firm.copyWith(pdfTemplate: style.id);
          final saleText = await renderedText(
            await InvoicePdf.forFirm(chosen)
                .build(invoice: invoice, items: items),
          );
          final purchaseText = await renderedText(
            await PurchasePdf.forFirm(chosen)
                .build(bill: bill, items: purchaseItems),
          );
          for (var i = 1; i <= 100; i++) {
            expect(
              saleText,
              contains('Product $i '),
              reason: '${style.id} lost sale line $i',
            );
            expect(
              purchaseText,
              contains('Supply $i '),
              reason: '${style.id} lost purchase line $i',
            );
          }
        }
      } finally {
        await db.close();
      }
    },
  );
}
