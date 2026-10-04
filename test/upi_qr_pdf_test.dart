import 'dart:io';

import 'package:atria/core/services/upi_qr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// `PdfGraphics.drawRect` only *appends* to the current path — it does not
/// paint. The UPI painter builds ~1200 module rectangles, so forgetting the
/// final `fillPath()` leaves them pending on the graphics state; the path then
/// survives every `q`/`Q` and is painted by whichever unrelated widget next
/// calls `fillPath()`, under that widget's transform. On a real invoice the QR
/// came out as a grey block across the terms and "Receiver's Signature"
/// instead of beside the "Scan to pay" caption.
///
/// The rendered artefact is not reachable from `flutter test` (no pdfium), so
/// this test asserts the property that causes it: the run of module rectangles
/// is closed by a fill operator before its frame is restored.
Future<List<int>> _bytesOf(pw.Widget qr) async {
  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(0),
      build: (context) => [
        pw.SizedBox(height: 200),
        pw.Container(
          padding: const pw.EdgeInsets.all(10),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Payment Details', style: pw.TextStyle(fontSize: 8)),
              pw.SizedBox(height: 6),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  qr,
                  pw.SizedBox(width: 10),
                  pw.Expanded(
                    child: pw.Text('Scan to pay via any UPI app'),
                  ),
                ],
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 20),
        // A later filled box — the kind of draw that used to steal the QR.
        pw.Container(width: 130, height: 20, color: PdfColors.grey300),
      ],
    ),
  );
  return doc.save();
}

/// The (single) page content stream, Flate-decoded.
String _content(List<int> bytes) {
  // Latin-1 keeps byte offsets and string indices in step.
  final raw = String.fromCharCodes(bytes);
  final start = raw.indexOf('stream');
  var s = start + 'stream'.length;
  while (raw.codeUnitAt(s) == 13 || raw.codeUnitAt(s) == 10) {
    s++;
  }
  final e = raw.indexOf('endstream', s);
  return String.fromCharCodes(ZLibDecoder().convert(bytes.sublist(s, e)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uri = 'upi://pay?pa=9100960692%40ybl&pn=Apex%20Integrations'
      '&am=1332.22&cu=INR';

  test('the UPI QR module rectangles are filled where they are drawn',
      () async {
    final content = _content(await _bytesOf(UpiQr.widget(uri, size: 86)!));

    // The maximal chain of `x y w h re` operators, plus whatever follows it.
    final chain = RegExp(
      r'(?:[-\d.]+\s+){4}re(?:\s+(?:[-\d.]+\s+){4}re)*\s+([A-Za-z*]+)',
    ).firstMatch(content);

    expect(chain, isNotNull, reason: 'the QR draws module rectangles');
    final op = chain!.group(1);
    expect(
      op,
      'f',
      reason: 'the module path must be filled in place, not left pending for '
          'the next widget to flush under its own transform',
    );

    // Sanity: this really is the QR's chain, not a stray rectangle.
    final rects = 're'.allMatches(chain.group(0)!);
    expect(rects.length, greaterThan(100));
  });

  test('the QR is laid out at the size it was asked for', () async {
    final content = _content(await _bytesOf(UpiQr.widget(uri, size: 86)!));
    final chain = RegExp(
      r'(?:[-\d.]+\s+){4}re(?:\s+(?:[-\d.]+\s+){4}re)*',
    ).firstMatch(content)!;
    final coords = RegExp(r'([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+) re')
        .allMatches(chain.group(0)!)
        .map((m) => [
              double.parse(m.group(1)!),
              double.parse(m.group(2)!),
              double.parse(m.group(3)!),
            ])
        .toList();
    final maxX = coords.map((c) => c[0] + c[2]).reduce((a, b) => a > b ? a : b);
    final maxY = coords.map((c) => c[1] + c[2]).reduce((a, b) => a > b ? a : b);

    expect(maxX, closeTo(86, 0.001));
    expect(maxY, closeTo(86, 0.001));
  });
}
