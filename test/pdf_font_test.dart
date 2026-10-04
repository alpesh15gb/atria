import 'package:atria/core/services/pdf_fonts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// The `pdf` package's built-in Helvetica is a Type1 font limited to U+00FF, so
/// `₹` (U+20B9) used to be substituted with a placeholder box in every invoice
/// and statement. [PdfFonts.theme] attaches the bundled Inter as a fallback,
/// which embeds a TrueType subset (`/FontFile2` in the PDF objects).
///
/// Without the fallback no font file can be embedded at all — that asymmetry is
/// what these two tests pin down, so a regression in the fallback wiring fails
/// here rather than silently shipping boxed rupee signs.
Future<String> _pdfWithAmount({required bool fallback}) async {
  final doc = pw.Document(
    theme: fallback ? await PdfFonts.theme() : pw.ThemeData.withFont(),
  );
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (context) => pw.Text('₹1,234.00 payable'),
    ),
  );
  return String.fromCharCodes(await doc.save());
}

void main() {
  // rootBundle needs a binding to read assets declared in pubspec.yaml.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the rupee sign is drawn from the bundled Inter fallback', () async {
    final pdf = await _pdfWithAmount(fallback: true);

    expect(
      pdf.contains('FontFile2'),
      isTrue,
      reason: 'Inter must be embedded as a TrueType subset so ₹ has a glyph',
    );
  });

  test('without the fallback there is no font to embed', () async {
    final pdf = await _pdfWithAmount(fallback: false);

    expect(pdf.contains('FontFile2'), isFalse);
  });
}
