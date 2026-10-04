import 'package:pdf/pdf.dart';

/// The look of a printed Atria document.
///
/// Three templates, chosen per firm in Firm Settings and stored on
/// `firms.pdfTemplate`. The reason it is per firm rather than per document:
/// printed material gets filed and handed to customers, so a shop picks one
/// look and keeps it. A book that printed a different layout depending on
/// which screen you happened to print from looks like a mistake.
///
/// Every field here is read by the PDF builders instead of a class-level
/// constant, which is what makes more than one layout possible at all. Adding a
/// template means adding a subclass here, not editing the builders.
class PdfTemplateStyle {
  const PdfTemplateStyle({
    required this.id,
    required this.name,
    required this.description,
    required this.brand,
    required this.brandDeep,
    required this.ink,
    required this.inkSoft,
    required this.line,
    required this.tint,
    required this.accentBand,
    required this.footerBand,
    required this.pageFormat,
    this.gutter = 34,
    this.usesHeaderBand = false,
    this.usesZebraRows = true,
  });

  /// The stored value on `firms.pdfTemplate`.
  final String id;

  /// Shown in the Firm Settings picker.
  final String name;

  /// One line under the name in the picker, so the choice is not a guess.
  final String description;

  /// The accent used for the items-table heading strip, the emphasised total,
  /// and the header band where [usesHeaderBand] is true.
  final PdfColor brand;

  /// Darker [brand], for figures that must carry weight against white.
  final PdfColor brandDeep;

  /// Body text.
  final PdfColor ink;

  /// Secondary text: labels, column headings, footnotes.
  final PdfColor inkSoft;

  /// Rules and cell borders.
  final PdfColor line;

  /// Zebra shading on alternating item rows.
  final PdfColor tint;

  /// The fill behind the GRAND TOTAL row.
  ///
  /// Carried as its own field rather than derived from [brand] because it was
  /// already a literal in the builder (`primaryContainer`), and deriving it
  /// would have quietly changed what `classic` prints.
  final PdfColor accentBand;

  /// The fill behind the per-page footer strip.
  final PdfColor footerBand;

  final PdfPageFormat pageFormat;

  /// Horizontal page margin, in points. Threaded rather than hardcoded so a
  /// template with wider furniture can breathe without every section method
  /// needing its own idea of it.
  final double gutter;

  /// Whether the page heading sits on a filled band. `classic` prints a
  /// shaded gradient instead, which reads more formal.
  final bool usesHeaderBand;

  /// Whether alternating item rows are shaded at all.
  final bool usesZebraRows;

  /// The current Atria layout: violet accents on a bordered, mostly white page.
  ///
  /// This is what the app printed before templates existed, deliberately
  /// unchanged, so upgrading a firm changes nothing about its output until its
  /// owner goes and picks something else.
  static const classic = PdfTemplateStyle(
    id: 'classic',
    name: 'Classic',
    description: 'Bordered and formal — the Atria default',
    brand: PdfColor.fromInt(0xFF6D28D9), // violet-700
    brandDeep: PdfColor.fromInt(0xFF4C1D95), // violet-900
    ink: PdfColor.fromInt(0xFF16141F),
    inkSoft: PdfColor.fromInt(0xFF565263),
    line: PdfColor.fromInt(0xFFD4D0E0),
    tint: PdfColor.fromInt(0xFFF6F5FA),
    accentBand: PdfColor.fromInt(0xFFEDE9FE),
    footerBand: PdfColor.fromInt(0xFFF5F3FF),
    pageFormat: PdfPageFormat.a4,
  );

  /// A solid brand band across the top of every page, no zebra rows. Bolder and
  /// more modern; the sort of invoice that reads as designed rather than filed.
  static const modern = PdfTemplateStyle(
    id: 'modern',
    name: 'Modern',
    description: 'Bold colour band, no zebra rows',
    brand: PdfColor.fromInt(0xFF4C1D95),
    brandDeep: PdfColor.fromInt(0xFF2E1065),
    ink: PdfColor.fromInt(0xFF16141F),
    inkSoft: PdfColor.fromInt(0xFF6B6780),
    line: PdfColor.fromInt(0xFFDDD9EC),
    tint: PdfColor.fromInt(0xFFFAF9FE),
    accentBand: PdfColor.fromInt(0xFFE9E4FF),
    footerBand: PdfColor.fromInt(0xFFEDE9FE),
    pageFormat: PdfPageFormat.a4,
    usesHeaderBand: true,
    usesZebraRows: false,
  );

  /// Ink and hairlines only. Prints cheapest and photocopies best, which is why
  /// a shop with a black-and-white office printer wants it.
  static const minimal = PdfTemplateStyle(
    id: 'minimal',
    name: 'Minimal',
    description: 'Plain black and white — photocopies best',
    brand: PdfColor.fromInt(0xFF3F3F46),
    brandDeep: PdfColor.fromInt(0xFF18181B),
    ink: PdfColor.fromInt(0xFF18181B),
    inkSoft: PdfColor.fromInt(0xFF71717A),
    line: PdfColor.fromInt(0xFFD4D4D8),
    tint: PdfColor.fromInt(0xFFFFFFFF),
    accentBand: PdfColor.fromInt(0xFFE4E4E7),
    footerBand: PdfColor.fromInt(0xFFFFFFFF),
    pageFormat: PdfPageFormat.a4,
  );

  /// Every template, in picker order.
  static const all = [classic, modern, minimal];

  /// Resolves a stored `firms.pdfTemplate` value to a style.
  ///
  /// Falls back to [classic] for anything unrecognised rather than throwing: a
  /// firm whose stored value is unknown should still print, and `classic` is
  /// exactly what it was printing before templates existed.
  ///
  /// Matching ignores case and surrounding spaces because the value can arrive
  /// from a restored backup or a hand-edited row, and reading "Modern" as
  /// unknown would silently print the wrong thing instead of the right one.
  static PdfTemplateStyle resolve(String? id) {
    final wanted = id?.trim().toLowerCase();
    if (wanted == null || wanted.isEmpty) return classic;
    for (final style in all) {
      if (style.id == wanted) return style;
    }
    return classic;
  }
}