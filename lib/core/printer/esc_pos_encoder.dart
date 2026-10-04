import 'dart:convert';
import 'dart:typed_data';

import 'printer_profile.dart';

/// One item line on a receipt.
///
/// Money and quantities arrive **already formatted**: the receipt must read
/// exactly like the invoice, and Apex Books's `Formatters` already owns how money
/// reads (lakh/crore grouping, the rupee glyph). Re-deriving an amount inside a
/// printer encoder would be a second implementation of the one thing that must
/// never disagree with the document.
class ReceiptItemLine {
  const ReceiptItemLine({
    required this.name,
    this.quantityText,
    this.rateText,
    required this.amountText,
    this.hsn,
  });

  final String name;

  /// "2 pcs" — quantity and unit together, already formatted.
  final String? quantityText;

  /// "₹500.00" — present when the line shows a rate of its own.
  final String? rateText;

  final String amountText;
  final String? hsn;
}

/// One line of the totals block ("CGST 9%", "Grand total", …).
class ReceiptTotalLine {
  const ReceiptTotalLine(this.label, this.value, {this.emphasise = false});

  final String label;
  final String value;

  /// Printed double-height, like the grand total on a till roll.
  final bool emphasise;
}

/// Everything a customer's receipt carries.
///
/// Deliberately a flat, already-resolved description rather than the database
/// entity: the same receipt has to be printable from the sale detail screen, the
/// POS and a reprint of an old invoice, and none of those should have to know
/// how the document is stored.
class ReceiptDocument {
  const ReceiptDocument({
    required this.firmName,
    required this.title,
    required this.number,
    required this.dateLine,
    this.firmGstin,
    this.firmAddress,
    this.firmPhone,
    this.partyName,
    this.partyGstin,
    this.items = const [],
    this.totals = const [],
    this.paidLine,
    this.balanceLine,
    this.terms,
    this.paymentLine,
    this.footerLine,
    this.isReprint = false,
  });

  /// The shop's trading name, centred at the top and printed large.
  final String firmName;

  /// `TAX INVOICE`, `ESTIMATE`, `CREDIT NOTE`, … already uppercased.
  final String title;

  final String number;

  /// "30 Sep 2026" — formatted by the caller, which owns the date format.
  final String dateLine;

  final String? firmGstin;
  final String? firmAddress;
  final String? firmPhone;
  final String? partyName;
  final String? partyGstin;
  final List<ReceiptItemLine> items;
  final List<ReceiptTotalLine> totals;

  /// "Paid by Cash" and similar, printed under the total when known.
  final String? paidLine;

  /// Balance still due, printed only when there is one.
  final String? balanceLine;

  final String? terms;

  /// The payment instruction, e.g. "Pay by UPI to shop@upi".
  final String? paymentLine;

  /// "Thank you" and the shop's phone number, at the foot of the roll.
  final String? footerLine;

  /// Marks a duplicate, so a reprinted invoice cannot pass for the original.
  final bool isReprint;
}

/// ESC/POS — the command language of every till-roll receipt printer.
///
/// A separate encoder from [LabelEncoder] because they are different problems:
/// a label printer is told where to put every element in dots on a die-cut
/// sticker, while a receipt printer is given a *stream of text* and lays it out
/// itself against the paper width. TSPL's `SIZE`/`BARCODE` mean nothing on a
/// till roll, and ESC/POS's `GS V` (cut) means nothing on a label printer.
///
/// The output is deliberately plain: ASCII text with alignment and size
/// commands. No images, no QR — a shop's receipt is a legal document and a
/// bitmap logo is the one thing that can fail halfway and print a black smear.
class EscPosEncoder {
  EscPosEncoder({
    required this.columns,
    this.cut = true,
    this.openDrawer = false,
  }) : assert(columns > 8, 'A receipt needs at least a few columns.');

  /// Characters per line. The industry default font on a 58 mm roll is 32
  /// columns, and on an 80 mm roll 48 — these are not derived from the paper
  /// width in millimetres, because the font is fixed and it is what every
  /// receipt printer's documentation quotes.
  final int columns;

  /// Whether to cut the paper after the receipt. Off for printers with a
  /// tear bar, and off for continuous roll testing.
  final bool cut;

  /// Whether to kick the cash drawer open. Worth having on a receipt printer:
  /// the drawer hangs off the printer, so a cash sale can open it in the same
  /// job that hands over the slip.
  final bool openDrawer;

  static const int columns58 = 32;
  static const int columns80 = 48;

  /// The encoder for a configured printer.
  ///
  /// The paper width picks the column count; a profile that has never been
  /// asked (a label printer being asked to print a receipt) gets 58 mm, which
  /// is what a cheap counter printer uses and what fits on either roll.
  static EscPosEncoder forProfile(PrinterProfile profile) => EscPosEncoder(
        columns: profile.paperWidthMm >= 80 ? columns80 : columns58,
        cut: profile.cutPaper,
        openDrawer: profile.openDrawer,
      );

  /// Renders the receipt as text, one entry per printed line.
  ///
  /// Public because it is what the encoder is *for*: a test can read the layout
  /// instead of decoding bytes, and a future on-screen preview gets the same
  /// lines the printer does.
  List<String> textLines(ReceiptDocument doc) => [
        for (final op in _layout(doc))
          if (op is _TextOp) op.text,
      ];

  /// The bytes to send to the printer.
  Uint8List encode(ReceiptDocument doc) {
    final out = BytesBuilder(copy: false);
    // ESC @ — initialise. Sent first so a printer left in a previous job's
    // double-height or underline mode does not print half the receipt wrong.
    _raw(out, [0x1B, 0x40]);

    for (final op in _layout(doc)) {
      switch (op) {
        case _TextOp(
            :final text,
            :final align,
            :final big,
            :final bold,
            :final rule,
          ):
          _raw(out, [
            0x1B, 0x61, align, // alignment for this block
          ]);
          _raw(out, [0x1B, 0x45, bold ? 1 : 0]); // bold
          _raw(out, [0x1D, 0x21, big ? 0x11 : 0x00]); // double width+height
          if (rule) {
            // A rule is drawn at normal width even when the row is emphasised:
            // a double-width dashed line is not a rule, it is a mistake.
            _raw(out, [0x1D, 0x21, 0x00]);
          }
          out.add(_ascii(text));
          _raw(out, [0x0A]);
          _raw(out, [0x1B, 0x45, 0]); // bold off
          _raw(out, [0x1D, 0x21, 0x00]); // size back to normal
        case _FeedOp(:final lines):
          _raw(out, [0x1B, 0x64, lines]); // ESC d n
      }
    }

    if (openDrawer) {
      // ESC p 0 25 250 — the pulse the drawer's solenoid expects. The two
      // timings are the specification's own defaults; a drawer that needs
      // longer is a hardware problem, not a setting.
      _raw(out, [0x1B, 0x70, 0x00, 0x19, 0xFA]);
    }

    if (cut) {
      // Feed clear of the head first, or the cut runs through the last line.
      _raw(out, [0x1B, 0x64, 0x04]);
      // GS V 1 — partial cut. A full cut drops the slip on the floor, which at
      // a counter means the customer's receipt lands behind the machine.
      _raw(out, [0x1D, 0x56, 0x01]);
    }

    return out.toBytes();
  }

  /// A short receipt that proves a fresh setup: paper width, alignment, bold,
  /// double height, and (if enabled) the drawer. Kept in the same encoder so a
  /// test print exercises exactly the code path a real receipt does.
  Uint8List encodeTest({String printerName = 'Apex Books test receipt'}) =>
      encode(testDocument(printerName: printerName));

  /// The test receipt's layout, as text — what a test asserts on, and what a
  /// future preview would show, without decoding bytes.
  List<String> textLinesForTest({String printerName = 'Apex Books test receipt'}) =>
      textLines(testDocument(printerName: printerName));

  /// The test receipt itself. Built here rather than in [encodeTest] so the
  /// text form and the byte form can never describe different receipts.
  ReceiptDocument testDocument({String printerName = 'Apex Books test receipt'}) =>
      ReceiptDocument(
        firmName: printerName,
        title: 'TEST PRINT',
        number: '-',
        dateLine: _stamp(),
        items: const [
          ReceiptItemLine(
            name: 'Item column, wrapping across two lines when the name is long',
            quantityText: '1 pcs',
            rateText: 'Rs.100.00',
            amountText: 'Rs.100.00',
          ),
        ],
        totals: [
          ReceiptTotalLine('Columns on this paper', '$columns'),
          const ReceiptTotalLine('Grand total', 'Rs.100.00', emphasise: true),
        ],
        paymentLine: cut
            ? 'Paper will be cut at the end of this job.'
            : 'Paper cutting is switched off for this printer.',
        footerLine: openDrawer
            ? 'The cash drawer should have opened.'
            : 'Cash drawer kick is switched off for this printer.',
      );

  // ---- Layout ------------------------------------------------------------

  List<_Op> _layout(ReceiptDocument doc) {
    final ops = <_Op>[];
    final ascii = _asciiSafe;

    ops.add(_TextOp(ascii(doc.firmName), align: _Align.center, big: true, bold: true));
    if ((doc.firmAddress ?? '').trim().isNotEmpty) {
      for (final line in _wrap(ascii(doc.firmAddress!), columns)) {
        ops.add(_TextOp(line, align: _Align.center));
      }
    }
    if ((doc.firmPhone ?? '').trim().isNotEmpty) {
      ops.add(_TextOp('Ph: ${ascii(doc.firmPhone!)}', align: _Align.center));
    }
    if ((doc.firmGstin ?? '').trim().isNotEmpty) {
      ops.add(
        _TextOp('GSTIN: ${ascii(doc.firmGstin!).toUpperCase()}',
            align: _Align.center),
      );
    }

    ops.add(_TextOp(ascii(doc.title).toUpperCase(), align: _Align.center, bold: true));
    ops.add(_TextOp(_rule(), align: _Align.center, rule: true));

    ops.add(_pair('Invoice', doc.number));
    ops.add(_pair('Date', doc.dateLine));
    if ((doc.partyName ?? '').trim().isNotEmpty) {
      // The customer's name wraps rather than being cut: a receipt with half a
      // name on it is not evidence of anything.
      final wrapped = _wrap(ascii(doc.partyName!), columns - 4);
      ops.add(_pair('Customer', wrapped.first));
      for (final extra in wrapped.skip(1)) {
        ops.add(_TextOp('    $extra'));
      }
    }
    if ((doc.partyGstin ?? '').trim().isNotEmpty) {
      ops.add(_pair('GSTIN', ascii(doc.partyGstin!).toUpperCase()));
    }
    if (doc.isReprint) {
      ops.add(_TextOp('*** DUPLICATE ***', align: _Align.center, bold: true));
    }

    ops.add(_TextOp(_rule(), rule: true));

    for (final item in doc.items) {
      for (final line in _wrap(ascii(item.name), columns)) {
        ops.add(_TextOp(line));
      }
      final detail = <String>[
        if ((item.hsn ?? '').trim().isNotEmpty) 'HSN ${ascii(item.hsn!)}',
        if ((item.quantityText ?? '').trim().isNotEmpty)
          ascii(item.quantityText!),
        if ((item.rateText ?? '').trim().isNotEmpty) '@ ${ascii(item.rateText!)}',
      ].join(' · ');
      // The quantity/rate line and the amount: the amount is right-aligned on a
      // line of its own when the row would not fit, because a wrapped amount is
      // unreadable at a counter.
      if (detail.isEmpty) {
        ops.add(_right(ascii(item.amountText)));
      } else if (detail.length + ascii(item.amountText).length + 1 <= columns) {
        ops.add(_twoColumns(detail, ascii(item.amountText)));
      } else {
        ops.add(_TextOp(detail));
        ops.add(_right(ascii(item.amountText)));
      }
    }

    ops.add(_TextOp(_rule(), rule: true));
    for (final total in doc.totals) {
      ops.add(_twoColumns(
        ascii(total.label),
        ascii(total.value),
        bold: total.emphasise,
      ));
    }

    if ((doc.paidLine ?? '').trim().isNotEmpty) {
      ops.add(_TextOp(ascii(doc.paidLine!), align: _Align.center));
    }
    if ((doc.balanceLine ?? '').trim().isNotEmpty) {
      ops.add(_twoColumns(
        'Balance due',
        ascii(doc.balanceLine!),
        bold: true,
      ));
    }

    ops.add(_TextOp(_rule(), rule: true));
    if ((doc.paymentLine ?? '').trim().isNotEmpty) {
      for (final line in _wrap(ascii(doc.paymentLine!), columns)) {
        ops.add(_TextOp(line, align: _Align.center));
      }
    }
    if ((doc.terms ?? '').trim().isNotEmpty) {
      for (final line in _wrap(ascii(doc.terms!), columns)) {
        ops.add(_TextOp(line));
      }
      ops.add(_TextOp(_rule(), rule: true));
    }
    if ((doc.footerLine ?? '').trim().isNotEmpty) {
      for (final line in _wrap(ascii(doc.footerLine!), columns)) {
        ops.add(_TextOp(line, align: _Align.center));
      }
    }
    ops.add(_TextOp('Powered by Apex Books', align: _Align.center));
    ops.add(const _FeedOp(3));
    return ops;
  }

  String _rule() => '-' * columns;

  /// A labelled row on the left of the paper: `Invoice        INV-001`.
  ///
  /// The label is padded to leave exactly the value's width, rather than padded
  /// to some fixed column and then having the value appended — which is what
  /// produced 39-character lines on a 32-column roll, i.e. a date the printer
  /// silently chopped in half.
  _TextOp _pair(String label, String value) {
    // A label that leaves no room for its value (a very long brand name on a
    // 58 mm roll) is truncated rather than allowed to overflow.
    if (label.length + 1 >= columns) {
      return _TextOp(label.substring(0, columns));
    }
    final room = columns - label.length - 1;
    final shown = value.length > room ? value.substring(0, room) : value;
    return _TextOp('${label.padRight(columns - shown.length)}$shown');
  }

  _TextOp _right(String value) =>
      _TextOp(value.padLeft(columns), align: _Align.right);

  /// Two columns padded to exactly the paper width.
  ///
  /// Padded rather than merely concatenated: a printer left-aligns whatever it
  /// is given, so the right-hand column only lands where it is meant to if the
  /// spaces are sent. Truncation is the fallback when the two do not fit —
  /// losing the tail of a long label beats wrapping a total onto a second line.
  _TextOp _twoColumns(String left, String right, {bool bold = false}) {
    if (left.length + right.length + 1 > columns) {
      final room = columns - right.length - 1;
      left = left.length > room && room > 0 ? left.substring(0, room) : left;
    }
    final pad = columns - left.length - right.length;
    return _TextOp(
      '$left${' ' * (pad < 1 ? 1 : pad)}$right',
      bold: bold,
    );
  }

  /// Greedy word wrap. Words longer than a line are hard-split, because a
  /// printer has no ellipsis and a silently dropped tail is worse than an
  /// ugly break.
  static List<String> _wrap(String text, int width) {
    if (width < 4) return [text];
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [''];
    final lines = <String>[];
    var current = '';
    for (final word in words) {
      if (current.isEmpty) {
        current = word;
      } else if (current.length + 1 + word.length <= width) {
        current = '$current $word';
      } else {
        lines.add(current);
        current = word;
      }
      while (current.length > width) {
        lines.add(current.substring(0, width));
        current = current.substring(width);
      }
    }
    if (current.isNotEmpty) lines.add(current);
    return lines;
  }

  // ---- Bytes -------------------------------------------------------------

  static void _raw(BytesBuilder out, List<int> bytes) => out.add(bytes);

  /// ASCII, because a receipt printer's default code page is not guaranteed to
  /// hold anything else — and the ₹ glyph is in *none* of them. Rupees are
  /// written "Rs." on the roll; see [LabelEncoder.money], whose translation
  /// this matches so a shop that prints both a label and a receipt sees the
  /// same money both times.
  static String _asciiSafe(String text) => _foldToAscii(text);

  static Uint8List _ascii(String text) {
    final folded = _foldToAscii(text);
    return Uint8List.fromList(ascii.encode(folded));
  }

  static String _foldToAscii(String text) {
    var out = text
        .replaceAll('₹', 'Rs.')
        .replaceAll('—', '-')
        .replaceAll('–', '-')
        .replaceAll('·', '-')
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll('’', "'")
        .replaceAll('‘', "'")
        .replaceAll('×', 'x');
    // Anything still outside ASCII (a shop name in Devanagari, say) becomes a
    // question mark per character rather than being dropped: a printer with the
    // right code page can be added later, but silently losing the name of the
    // business on its own receipt is not a fallback.
    final buffer = StringBuffer();
    for (final rune in out.runes) {
      buffer.writeCharCode(rune <= 0x7E && rune >= 0x20 ? rune : 0x3F);
    }
    return buffer.toString();
  }

  static String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.day)}/${two(now.month)}/${now.year} '
        '${two(now.hour)}:${two(now.minute)}';
  }
}

/// Raised when a receipt cannot be encoded.
///
/// The same type the label path throws, so the print button in the UI has one
/// failure to catch and one message to show.
class ReceiptException implements Exception {
  const ReceiptException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// ESC/POS alignment codes.
class _Align {
  static const int left = 0;
  static const int center = 1;
  static const int right = 2;
}

sealed class _Op {
  const _Op();
}

class _TextOp extends _Op {
  const _TextOp(
    this.text, {
    this.align = _Align.left,
    this.big = false,
    this.bold = false,
    this.rule = false,
  });

  final String text;
  final int align;
  final bool big;
  final bool bold;

  /// Marks a full-width dashed rule. Drawn at normal width even in an
  /// emphasised block — see [EscPosEncoder.encode].
  final bool rule;
}

class _FeedOp extends _Op {
  const _FeedOp(this.lines);

  final int lines;
}
