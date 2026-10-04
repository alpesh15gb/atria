
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
  ///
  /// Never throws on a barcode: a value Code 128 cannot carry loses its bars and
  /// keeps its text (see [_code128Bars]), because this is a bulk sheet and one
  /// item's free-text barcode field must not cost the operator the other 35
  /// labels.
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
    final bars = _code128Bars(code);
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
          if (bars != null)
            pw.BarcodeWidget(
              barcode: pw.Barcode.code128(),
              // Defensive: the barcode package throws on non-ASCII, which
              // `_code128Bars` is what filters out. Nothing in the build path
              // may throw — see the note on `build`.
              data: _code128Bars(bars) ?? '',
              width: 160,
              height: 38,
              drawText: true,
            )
          else
            // Code 128 carries ASCII 0-127 and nothing else, and the encoder
            // throws on the first character outside that. A shop's own barcode
            // field is free text, so one "café" or a Devanagari name used as a
            // code would otherwise take the *whole sheet* down — 35 other
            // labels, all perfectly printable, lost to one bad field.
            //
            // So the bars are dropped and the value is printed as text: the
            // label still exists, the code is still readable and can be typed
            // at the counter, and the failure is visible as a label with no
            // barcode rather than as an exception. Refusing the sheet instead
            // would mean an operator cannot print a price sheet until they
            // find and fix one field on one item.
            pw.Container(
              width: 160,
              height: 38,
              alignment: pw.Alignment.center,
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
              ),
              child: pw.Text(
                'Not a barcode',
                style: pw.TextStyle(
                  fontSize: 6,
                  color: PdfColors.grey700,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
          pw.SizedBox(height: 2),
          // Printed whatever happened above: the barcode's own caption is drawn
          // by the bars, so this is what carries the value when there are none.
          if (bars == null)
            pw.Text(
              code,
              maxLines: 2,
              overflow: pw.TextOverflow.clip,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(fontSize: 6, color: PdfColors.grey700),
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

  /// The value to put in Code 128 bars, or null when it cannot go in them.
  ///
  /// Code 128 encodes ASCII 0x00-0x7F; the `barcode` package throws a
  /// `BarcodeException` naming the offending character for anything above that,
  /// which is why this is checked before the widget is built rather than caught
  /// around it. Non-printable and control characters are dropped rather than
  /// refused, because a stray newline typed into a barcode field is a typo, not
  /// a different product — what remains is still what the operator meant to
  /// scan. Anything non-ASCII at all is refused outright: substituting a
  /// lookalike would print a barcode that scans to the wrong string, which is
  /// worse than printing no barcode.
  static String? _code128Bars(String code) {
    final buffer = StringBuffer();
    for (final unit in code.codeUnits) {
      if (unit > 0x7f) return null;
      if (unit < 0x20 || unit == 0x7f) continue;
      buffer.writeCharCode(unit);
    }
    return buffer.isEmpty ? null : buffer.toString();
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
