import 'dart:convert';
import 'dart:typed_data';

import 'printer_profile.dart';

/// The barcode symbologies Atria will print.
///
/// All three exist in both TSPL and ZPL, which is why these are the only ones
/// offered — a symbology the target printer cannot render prints as literal
/// text, and a label without a working barcode is worse than no label, because
/// the shopkeeper only finds out at the counter.
enum BarcodeSymbology {
  /// Any length, full printable ASCII. The default for internal item codes.
  code128('Code 128', '128', '^BC'),

  /// Fixed 12 digits plus a check digit. What retail packaging carries, so an
  /// item scanned off a supplier's box keeps its original number.
  ean13('EAN-13', 'EAN13', '^BE'),

  /// Uppercase alphanumeric, no check digit. Still common on older stock.
  code39('Code 39', '39', '^B3');

  const BarcodeSymbology(this.label, this.tsplName, this.zplCommand);

  final String label;

  /// TSPL `BARCODE` type, e.g. `"EAN13"`.
  final String tsplName;

  /// ZPL barcode command, e.g. `^BE`.
  final String zplCommand;

  static BarcodeSymbology parse(String? value) => values.firstWhere(
        (symbology) => symbology.name == (value ?? '').toLowerCase(),
        orElse: () => BarcodeSymbology.code128,
      );
}

/// Raised when a label cannot be encoded. The message is written to be shown to
/// the operator verbatim.
class LabelException implements Exception {
  const LabelException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One thing to print: a product sticker.
///
/// Money arrives here already formatted. Atria's own `Formatters` owns how money
/// reads (lakh/crore grouping, the rupee glyph), and a printer has no locale —
/// so re-deriving the amount inside the encoder would be a second
/// implementation of the one thing that must never disagree with the invoice.
/// [LabelEncoder.money] only translates the result into glyphs a printer has.
class LabelDocument {
  const LabelDocument({
    required this.title,
    required this.barcode,
    required this.symbology,
    this.priceLine,
    this.strikethroughLine,
    this.subtitle,
    this.footer,
    this.copies = 1,
  });

  /// The item name, printed at the top and shrunk to fit the label width.
  final String title;

  /// The value encoded in the bars *and* printed under them, so a broken
  /// scanner can still be typed in at the counter.
  final String barcode;
  final BarcodeSymbology symbology;

  /// The selling price, already formatted, e.g. `₹1,180.00`.
  final String? priceLine;

  /// The MRP when it differs from the selling price — printed small, because
  /// neither TSPL nor ZPL can strike text through.
  final String? strikethroughLine;

  /// A second line under the name, e.g. the SKU or HSN.
  final String? subtitle;

  /// A line at the very bottom, e.g. the shop's name.
  final String? footer;

  final int copies;
}

/// Turns a [LabelDocument] into the bytes a printer accepts.
///
/// The two encoders share the same layout arithmetic and differ only in the
/// command set, because TSPL and ZPL agree on the important things: both draw in
/// dots from the top-left and both take a magnified bitmap font. Keeping one
/// layout and two dialects means a label that looks right on a TSC looks right
/// on a Zebra — which is the point, since shops run both.
///
/// All layout is computed in **dots**. TSPL's `SIZE`/`GAP` take millimetres
/// while its coordinates do not, and mixing the two units is what makes
/// hand-written label code drift as the head resolution changes.
sealed class LabelEncoder {
  const LabelEncoder(this.profile);

  final PrinterProfile profile;

  double get dotsPerMm => profile.dotsPerMm;

  /// Millimetres to dots — the only place the scale is applied.
  int mm(double millimetres) => (millimetres * dotsPerMm).round();

  /// Chooses the encoder for [profile]'s brand — the only place the brand is
  /// switched on, so a new brand is one case here plus one encoder.
  static LabelEncoder forProfile(PrinterProfile profile) =>
      switch (profile.brand) {
        PrinterBrand.tsc => TsplEncoder(profile),
        PrinterBrand.zebra => ZplEncoder(profile),
      };

  /// Encodes [label] for this printer.
  ///
  /// Throws [LabelException] when [label]'s symbology cannot represent its
  /// barcode — an EAN-13 label with a 7-digit code, say. Bars no scanner can
  /// read is the one failure worth refusing outright.
  Uint8List encode(LabelDocument label);

  /// Encodes [documents] as one print job per label, in order, so a 20-label
  /// run is a single connection rather than 20.
  Uint8List encodeAll(List<LabelDocument> documents) {
    if (documents.isEmpty) {
      throw const LabelException('There is nothing to print.');
    }
    final builder = BytesBuilder(copy: false);
    for (final document in documents) {
      builder.add(encode(document));
    }
    return builder.takeBytes();
  }

  /// A label that exercises every element, for the settings screen's test
  /// print. It is laid out for *this* profile, so it also proves the geometry
  /// is right: a test label drawn off the edge means the size is wrong.
  Uint8List encodeTestLabel() => encode(
        LabelDocument(
          title: 'Test label',
          subtitle: 'Atria',
          // Code 128 accepts any printable ASCII, so the test print cannot be
          // defeated by whatever symbology is configured.
          barcode: 'ATRIA123456',
          symbology: BarcodeSymbology.code128,
          priceLine: 'Rs 1234.00',
          footer: profile.name,
        ),
      );

  /// Resolves the value actually sent to the printer, or throws when
  /// [symbology] cannot represent [value].
  ///
  /// Returns EAN-13 *without* its check digit: both TSPL and ZPL compute the
  /// final digit themselves, and a 13-digit value makes them either reject the
  /// command or print a 14th bar.
  static String resolveBarcode(String value, BarcodeSymbology symbology) {
    final text = value.trim();
    if (text.isEmpty) {
      throw const LabelException(
        'This item has no barcode, and no item code to fall back on.',
      );
    }
    switch (symbology) {
      case BarcodeSymbology.code128:
        for (final unit in text.codeUnits) {
          if (unit < 32 || unit > 126) {
            throw const LabelException(
              'Code 128 needs printable ASCII, with no control characters, so '
              'this value cannot be printed in it.',
            );
          }
        }
        return text;
      case BarcodeSymbology.code39:
        final upper = text.toUpperCase();
        if (!RegExp(r'^[0-9A-Z \-.$/+%]+$').hasMatch(upper)) {
          throw const LabelException(
            'Code 39 can only encode A-Z, 0-9 and - . space / + %, so this '
            'value cannot be printed in it.',
          );
        }
        return upper;
      case BarcodeSymbology.ean13:
        if (!RegExp(r'^\d{12,13}$').hasMatch(text)) {
          throw LabelException(
            'EAN-13 needs 12 or 13 digits, and this value has '
            '${text.length} character(s).',
          );
        }
        if (text.length == 13) {
          final expected = ean13CheckDigit(text.substring(0, 12));
          if (expected != text[12]) {
            throw LabelException(
              'The EAN-13 check digit is wrong: $text should end in $expected. '
              'Printing it would make a barcode no scanner accepts.',
            );
          }
        }
        // Drop the check digit; the printer adds it back.
        return text.substring(0, 12);
    }
  }

  /// The EAN-13 check digit for the first 12 digits.
  ///
  /// Weights alternate 1,3 from the left; the digit is whatever brings the
  /// weighted sum to a multiple of ten.
  static String ean13CheckDigit(String first12) {
    var sum = 0;
    for (var i = 0; i < first12.length; i++) {
      final digit = int.parse(first12[i]);
      sum += i.isEven ? digit : digit * 3;
    }
    return ((10 - (sum % 10)) % 10).toString();
  }

  /// Whether [value] is 13 digits with a *correct* check digit — used by the
  /// item editor to tell a real EAN from a typed-in number.
  static bool isValidEan13(String value) {
    final text = value.trim();
    if (!RegExp(r'^\d{13}$').hasMatch(text)) return false;
    return ean13CheckDigit(text.substring(0, 12)) == text[12];
  }

  /// Money as a printer can render it.
  ///
  /// Neither printer's built-in font has the rupee glyph, and a missing glyph
  /// prints as a blank box on a TSPL label — so `₹` becomes `Rs` here. Only
  /// the currency marker is translated; the digits, the grouping and the
  /// decimals are exactly what `Formatters.money` produced.
  static String money(String? formatted) {
    final text = (formatted ?? '')
        .replaceAll('\u20b9', 'Rs')
        .replaceAll('Rs.', 'Rs')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (rune >= 0x20 && rune <= 0x7e) buffer.writeCharCode(rune);
    }
    return buffer.toString().trim();
  }

  /// Strips what a printer cannot render and what would break its command
  /// syntax, without silently dropping text the operator expected.
  ///
  /// Quotes and backslashes are TSPL control characters inside a string
  /// literal, and `^`/`~` are ZPL's. They are folded to lookalikes rather than
  /// escaped, because the alternative — a doubled quote — reads as a typo on
  /// the printed label, and an item genuinely called `3" PVC` should look like
  /// `3" PVC`.
  String printable(String? value) {
    final text = (value ?? '')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return '';
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      switch (rune) {
        case 0x22: // "
          buffer.write("'");
        case 0x5c: // backslash
          buffer.write('/');
        case 0x5e: // ^ — ZPL's field terminator
          buffer.write(' ');
        case 0x7e: // ~ — ZPL's control prefix
          buffer.write('-');
        default:
          // TSPL's built-in font is single-byte; anything above ASCII would
          // print as a glyph from another codepage, which is worse than
          // dropping it. ZPL with ^CI28 could show it, but keeping the two
          // encoders identical is worth more than one script on a price tag.
          if (rune >= 0x20 && rune <= 0x7e) buffer.writeCharCode(rune);
      }
    }
    return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// How many dots tall one line of the printer's built-in font is at 1×, per
  /// resolution. Font `3` is 16×24 dots at 203 dpi; font `2` is 12×20 at 300.
  int get baseFontHeight => profile.dpi >= 300 ? 20 : 24;

  /// How many dots wide one character is at 1× — used to decide the smallest
  /// magnification a name can be printed at without running off the label.
  int get baseFontWidth => profile.dpi >= 300 ? 12 : 16;

  /// The magnification a [characters]-long line can use on this label.
  ///
  /// Never returns 0: a name too long to fit at any magnification is printed at
  /// 1× and clipped by the printer, which the operator can see and fix. Silently
  /// printing nothing would look like a printer fault.
  int fitScale(int characters, {int preferred = 2, double reserveMm = 2}) {
    if (characters <= 0) return preferred;
    final available = profile.labelWidthDots - mm(reserveMm);
    final needed = characters * baseFontWidth.toDouble();
    if (needed <= 0) return preferred;
    return (available / needed).floor().clamp(1, preferred);
  }
}

// ---------------------------------------------------------------------------
// TSPL (TSC)
// ---------------------------------------------------------------------------

/// TSC's TSPL / TSPL2.
///
/// Every coordinate is in **dots**, while `SIZE` and `GAP` are in millimetres —
/// the one mixed-unit rule that catches everyone writing these by hand, so the
/// conversion goes through [mm] and nowhere else.
class TsplEncoder extends LabelEncoder {
  const TsplEncoder(super.profile);

  @override
  Uint8List encode(LabelDocument label) {
    final value = LabelEncoder.resolveBarcode(label.barcode, label.symbology);

    // A 1:3 narrow:wide ratio is the Code 128 and Code 39 convention. At 203
    // dpi two dots is a 0.25 mm module, which reads on the cheap scanners shops
    // actually use; one dot is printable but marginal.
    const narrow = 2;
    const wide = narrow * 3;
    final barHeight = (profile.labelHeightDots * 0.38).round().clamp(20, 400);

    final commands = <String>[
      'SIZE ${_mm(profile.labelWidthMm)} mm,${_mm(profile.labelHeightMm)} mm',
      'GAP ${_mm(profile.gapMm)} mm,0 mm',
      // Direction 1 orients the label the normal way up. Stated rather than
      // omitted, because a printer whose stock feeds the other way round needs
      // 0, and leaving it out makes that look like a broken printer.
      'DIRECTION 1',
      'REFERENCE ${mm(profile.offsetXMm)},${mm(profile.offsetYMm)}',
      'DENSITY ${profile.darkness}',
      'SPEED ${profile.speed}',
      'CLS',
    ];

    final left = mm(1);
    var y = mm(1);

    final nameScale = fitScale(label.title.length, preferred: 2);
    commands.add(_text(left, y, label.title, scale: nameScale, bold: true));
    y += baseFontHeight * nameScale + mm(0.6);

    if (printable(label.subtitle).isNotEmpty) {
      commands.add(_text(left, y, label.subtitle!, scale: 1));
      y += baseFontHeight + mm(0.4);
    }

    commands.add(
      'BARCODE $left,$y,"${label.symbology.tsplName}",$barHeight,1,0,'
      '$narrow,$wide,"$value"',
    );
    y += barHeight + mm(1.2);

    final price = LabelEncoder.money(label.priceLine);
    if (price.isNotEmpty) {
      final priceScale = fitScale(price.length, preferred: 2, reserveMm: 1);
      commands.add(_text(left, y, price, scale: priceScale, bold: true));
      y += baseFontHeight * priceScale + mm(0.4);
    }

    final mrp = LabelEncoder.money(label.strikethroughLine);
    if (mrp.isNotEmpty) {
      // No strikethrough in TSPL, so the MRP is labelled instead of left to
      // look like the current price.
      commands.add(_text(left, y, 'MRP $mrp', scale: 1));
      y += baseFontHeight + mm(0.3);
    }

    final footer = printable(label.footer);
    if (footer.isNotEmpty && y < profile.labelHeightDots - baseFontHeight) {
      commands.add(_text(left, y, footer, scale: 1));
    }

    // `PRINT <sets>,<copies>`: TSPL counts copies per set, so copies is the
    // second field and there is exactly one set.
    commands.add('PRINT 1,${label.copies.clamp(1, 50)}');
    return _ascii(commands.join('\r\n'));
  }

  String _text(int x, int y, String raw, {required int scale, bool bold = false}) {
    // TSPL has no bold; a doubled y-magnification on the name and price is what
    // makes them read as headings at a glance.
    final font = profile.dpi >= 300 ? '2' : '3';
    return 'TEXT $x,$y,"$font",0,$scale,${bold ? scale + 1 : scale},'
        '"${printable(raw)}"';
  }

  /// TSPL is a single-byte protocol. The command text is ASCII by construction
  /// (`printable` guarantees it), so latin1 is exact and cannot emit a
  /// multi-byte sequence a printer would read as two junk glyphs.
  static Uint8List _ascii(String text) =>
      Uint8List.fromList(latin1.encode('$text\r\n'));

  static String _mm(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);
}

// ---------------------------------------------------------------------------
// ZPL (Zebra)
// ---------------------------------------------------------------------------

/// Zebra's ZPL II.
///
/// Everything is in dots, and the field origin is set explicitly with `^FO`
/// before each element so a skipped command cannot leave the next one drawing
/// from the wrong place.
class ZplEncoder extends LabelEncoder {
  const ZplEncoder(super.profile);

  @override
  Uint8List encode(LabelDocument label) {
    final value = LabelEncoder.resolveBarcode(label.barcode, label.symbology);
    final barHeight = (profile.labelHeightDots * 0.38).round().clamp(20, 400);

    final commands = <String>[
      '^XA',
      // UTF-8 input, so a name typed in a regional script reaches the printer
      // intact instead of being mangled by the default codepage.
      '^CI28',
      '^PW${profile.labelWidthDots}',
      '^LL${profile.labelHeightDots}',
      // Media tracking. `Y` is non-continuous (die-cut, gap-sensed), `N` is
      // continuous roll. Getting this backwards makes a gap printer feed a
      // whole label between labels, which reads as a wasted-stock fault.
      if (profile.gapMm > 0) '^MNY' else '^MNN',
      // Darkness: `~SD` runs 0-30 against TSPL's DENSITY 0-15, so the profile
      // stores one scale and it is doubled here.
      '~SD${(profile.darkness * 2).clamp(0, 30)}',
      '^PR${profile.speed}',
      // Calibration, as a whole-label shift rather than added to every
      // coordinate — otherwise it would be applied twice.
      if (profile.offsetXMm != 0) '^LS${mm(profile.offsetXMm)}',
      if (profile.offsetYMm != 0) '^LT${mm(profile.offsetYMm)}',
    ];

    final left = mm(1);
    var y = mm(1);

    final nameHeight =
        (baseFontHeight * fitScale(label.title.length, preferred: 3)) ~/ 2 * 2;
    commands.add('^FO$left,$y^A0N,$nameHeight,$nameHeight'
        '^FD${printable(label.title)}^FS');
    y += nameHeight + mm(1);

    if (printable(label.subtitle).isNotEmpty) {
      commands.add('^FO$left,$y^A0N,20,20^FD${printable(label.subtitle!)}^FS');
      y += mm(3.5);
    }

    // `^BY<narrow>,<ratio>,<height>` then the barcode command; ratio 3 is the
    // same 1:3 narrow:wide convention TSPL is given above.
    commands.add('^FO$left,$y^BY2,3,$barHeight${label.symbology.zplCommand}N,'
        '$barHeight,Y,N,N^FD$value^FS');
    y += barHeight + mm(2);

    final price = LabelEncoder.money(label.priceLine);
    if (price.isNotEmpty) {
      final priceHeight =
          (baseFontHeight * fitScale(price.length, preferred: 3, reserveMm: 1)) ~/ 2 * 2;
      commands.add('^FO$left,$y^A0N,$priceHeight,$priceHeight^FD$price^FS');
      y += priceHeight + mm(1);
    }

    final mrp = LabelEncoder.money(label.strikethroughLine);
    if (mrp.isNotEmpty) {
      // ZPL has no strikethrough either, so the same MRP marker as TSPL.
      commands.add('^FO$left,$y^A0N,20,20^FDMRP $mrp^FS');
      y += mm(3.5);
    }

    final footer = printable(label.footer);
    if (footer.isNotEmpty && y < profile.labelHeightDots - baseFontHeight) {
      commands.add('^FO$left,$y^A0N,20,20^FD$footer^FS');
    }

    commands.add('^PQ${label.copies.clamp(1, 50)}');
    commands.add('^XZ');
    return Uint8List.fromList(utf8.encode(commands.join('\n')));
  }
}
