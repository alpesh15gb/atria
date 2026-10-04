import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

/// Font plumbing for the generated PDFs.
///
/// The `pdf` package's built-in Helvetica is a Type1 font with a 256-glyph
/// WinAnsi table, so `isRuneSupported` is false for anything above U+00FF —
/// including the rupee sign, U+20B9. Every `₹` in an invoice, quotation or
/// statement was therefore drawn as a **placeholder box** (the layout code
/// substitutes one and prints "Unable to find a font to draw…" in debug).
///
/// Inter ships with the app and does carry `₹`, so it is attached as a
/// *fallback* rather than a replacement: the document still uses Helvetica for
/// everything else, so metrics, line breaks and column widths are unchanged
/// from before, and only the unsupported runes are drawn from Inter.
class PdfFonts {
  PdfFonts._();

  static const _interAsset = 'assets/fonts/Inter[opsz,wght].ttf';

  static pw.Font? _cached;

  /// Set once loading has failed, so a missing asset bundle (unit tests) is
  /// not retried for every document.
  static bool _unavailable = false;

  /// Inter as a fallback list, or empty when the asset cannot be read — in
  /// which case the PDF still builds, it just shows the placeholder again.
  static Future<List<pw.Font>> fallback() async {
    final cached = _cached;
    if (cached != null) return [cached];
    if (_unavailable) return const [];
    try {
      final data = await rootBundle.load(_interAsset);
      return [_cached = pw.Font.ttf(data)];
    } catch (_) {
      _unavailable = true;
      return const [];
    }
  }

  /// The document theme: the package default plus the fallback.
  ///
  /// `pw.ThemeData.withFont()` is exactly what a `Document` uses when no theme
  /// is given (`ThemeData.base()` delegates to it), so passing only
  /// `fontFallback` leaves every other font slot untouched.
  static Future<pw.ThemeData> theme() async {
    return pw.ThemeData.withFont(fontFallback: await fallback());
  }
}
