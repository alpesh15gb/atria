
import 'package:decimal/decimal.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../database/app_database.dart';
import '../utils/formatters.dart';

/// Renders printable Code128 barcode labels on an A4 sheet — Vyapar's barcode
/// generator, offline. Each label shows the item name, price and a scannable
/// barcode (the item's saved barcode, or its id when none is set).
class BarcodeLabels {
  BarcodeLabels._();

  /// Builds a one-page-per-call PDF with [labelsPerRow] x ~13 labels.
  static Future<pw.Document> build({
    required List<ItemEntity> items,
    int labelsPerRow = 3,
  }) async {
    final doc = pw.Document();
    final perPage = labelsPerRow * 12;

    for (var page = 0; page * perPage < items.length; page++) {
      final slice = items.skip(page * perPage).take(perPage).toList();
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(18),
          build: (context) => pw.Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in slice) _label(item),
            ],
          ),
        ),
      );
    }
    return doc;
  }

  static pw.Widget _label(ItemEntity item) {
    final code = _codeFor(item);
    return pw.Container(
      width: 180,
      padding: const pw.EdgeInsets.all(6),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
      ),
      child: pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            item.name,
            maxLines: 1,
            overflow: pw.TextOverflow.clip,
            style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 2),
          pw.BarcodeWidget(
            barcode: pw.Barcode.code128(),
            data: code,
            width: 160,
            height: 38,
            drawText: true,
          ),
          pw.SizedBox(height: 2),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                Formatters.money(Decimal.parse(item.salePrice.toStringAsFixed(2))),
                style: pw.TextStyle(
                    fontSize: 9, fontWeight: pw.FontWeight.bold),
              ),
              if (item.mrp != null && item.mrp! > 0)
                pw.Text(
                  'MRP ${Formatters.money(Decimal.parse(item.mrp!.toStringAsFixed(2)))}',
                  style: pw.TextStyle(
                      fontSize: 7,
                      color: PdfColors.grey700,
                      decoration: pw.TextDecoration.lineThrough),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The value encoded in the barcode. A saved EAN/Code value is used as-is;
  /// otherwise the full item id stands in. The old first-12-chars fallback
  /// truncated a UUIDv7 to its millisecond timestamp — two items created in
  /// the same millisecond printed IDENTICAL barcodes.
  static String _codeFor(ItemEntity item) {
    final barcode = item.barcode?.trim() ?? '';
    if (barcode.isNotEmpty) return barcode;
    return item.id.toUpperCase();
  }
}
