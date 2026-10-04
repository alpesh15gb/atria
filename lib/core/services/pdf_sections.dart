import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_template_style.dart';

import '../constants/app_constants.dart';
import '../database/app_database.dart';
import '../utils/formatters.dart';
import 'upi_qr.dart';

/// A printed line item, reduced to what a document actually prints about it.
///
/// Both a sales invoice and a purchase bill carry the same eight figures per
/// line, on two row types that are otherwise field-for-field identical. This is
/// the shape that lets one table draw both: the builders map their own entity
/// into it and stop there, so the heading strip, the zebra rows, the tax columns
/// and the page-break behaviour exist exactly once.
class PdfLineItem {
  const PdfLineItem({
    required this.name,
    required this.quantity,
    required this.rate,
    required this.taxableValue,
    required this.total,
    this.hsn,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.gstRate = 0,
  });

  factory PdfLineItem.fromSales(SalesInvoiceItemEntity e) => PdfLineItem(
        name: e.name,
        hsn: e.hsn,
        quantity: e.quantity,
        rate: e.rate,
        taxableValue: e.taxableValue,
        total: e.total,
        cgst: e.cgst,
        sgst: e.sgst,
        igst: e.igst,
        gstRate: e.gstRate,
      );

  factory PdfLineItem.fromPurchase(PurchaseBillItemEntity e) => PdfLineItem(
        name: e.name,
        hsn: e.hsn,
        quantity: e.quantity,
        rate: e.rate,
        taxableValue: e.taxableValue,
        total: e.total,
        cgst: e.cgst,
        sgst: e.sgst,
        igst: e.igst,
        gstRate: e.gstRate,
      );

  final String name;
  final String? hsn;
  final num quantity;
  final num rate;
  final num taxableValue;
  final num total;
  final num cgst;
  final num sgst;
  final num igst;
  final num gstRate;
}

/// One addressee on a printed document.
///
/// A sales invoice has a customer in two columns; a purchase bill has the
/// supplier and the firm's own delivery address; a receipt has exactly one
/// payee. Modelling it as a value keeps the two-column bordered box from having
/// to grow a third shape.
class PdfParty {
  const PdfParty({
    required this.label,
    required this.name,
    this.address,
    this.gstin,
    this.state,
  });

  final String label;
  final String name;
  final String? address;
  final String? gstin;
  final String? state;
}

/// A labelled figure in the totals block.
class PdfTotalRow {
  const PdfTotalRow(this.label, this.value, {this.emphasize = false});

  final String label;
  final String value;
  final bool emphasize;
}

/// Everything on an Atria document that does not depend on what kind of
/// document it is: the header band, the party boxes, the items table, the
/// totals block, the words, the signature line and the page footer.
///
/// Sales and purchase documents extend this rather than each carrying their own
/// copy. That was not a style preference: the two row types are identical, so
/// duplicating the table would have meant two places where the continuation-page
/// heading strip, the zebra shading or the tax-column widths could be fixed for
/// one document kind and not the other.
///
/// Subclasses supply the document-specific parts: which title, which totals
/// rows, which tax columns, and whether there is anything to collect.
abstract class PdfSections {
  PdfSections(this.firm, this.style);

  final FirmEntity firm;
  final PdfTemplateStyle style;

  /// Database columns are `REAL`; the formatters want exact [Decimal]s.
  Decimal dec(num value) => Decimal.parse(value.toString());

  // ---- Furniture ---------------------------------------------------------

  /// A rounded, bordered panel — the box the party blocks and the words sit in.
  pw.Widget panel(pw.Widget child,
      {pw.EdgeInsets padding = const pw.EdgeInsets.all(10)}) {
    return _box(padding, child);
  }

  /// The same panel holding a stack of blocks.
  ///
  /// Takes a list rather than a single child so callers do not nest a `Column`
  /// inside the panel's own `Column`. The nesting costs nothing visually, but it
  /// does emit a redundant transform operator per child, which is exactly the
  /// kind of difference that makes an output-equality check noisy and useless.
  pw.Widget panelOf(List<pw.Widget> children,
      {pw.EdgeInsets padding = const pw.EdgeInsets.all(10)}) {
    return _box(
      padding,
      pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  pw.Widget _box(pw.EdgeInsets padding, pw.Widget child) {
    return pw.Container(
      width: double.infinity,
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: style.line, width: 0.7),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      padding: padding,
      child: child,
    );
  }

  /// The coloured band across the top of every page.
  ///
  /// [stamp] is an optional short badge under the document number — "PAID IN
  /// FULL" on a settled invoice. It lives here rather than in `invoice_pdf.dart`
  /// because a paid purchase bill wants the same mark, and a stamp implemented
  /// once per builder is a stamp that ends up on one kind of document and not
  /// the other.
  pw.Widget header({
    required String title,
    required String number,
    String? stamp,
  }) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        // `modern` fills the whole heading rather than shading it, so the two
        // read as genuinely different documents rather than the same one with
        // the gradient turned down.
        color: style.usesHeaderBand ? style.brand : null,
        gradient: style.usesHeaderBand
            ? null
            : pw.LinearGradient(
                begin: pw.Alignment.topLeft,
                end: pw.Alignment.bottomRight,
                colors: [style.brand, style.brandDeep],
              ),
      ),
      padding: pw.EdgeInsets.fromLTRB(style.gutter, 20, style.gutter, 20),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // Firm logo, when one is set in Firm Profile. Read at build time
          // from logoPath; a missing/corrupt file degrades to the text-only
          // header instead of failing the whole PDF.
          if ((firm.logoPath ?? '').isNotEmpty && _exists(firm.logoPath!))
            _logoChip(firm.logoPath!),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  firm.name.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 19,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.white,
                    letterSpacing: 0.6,
                  ),
                ),
                pw.SizedBox(height: 4),
                if ((firm.addressLine1 ?? '').isNotEmpty) ...[
                  pw.Text(
                    _address(),
                    style: pw.TextStyle(
                      fontSize: 9.2,
                      color: PdfColors.white,
                      height: 1.5,
                    ),
                  ),
                ],
                pw.SizedBox(height: 4),
                pw.Wrap(
                  spacing: 14,
                  runSpacing: 2,
                  children: [
                    if ((firm.gstin ?? '').isNotEmpty)
                      _metaChip('GSTIN', firm.gstin!.toUpperCase()),
                    if ((firm.pan ?? '').isNotEmpty)
                      _metaChip('PAN', firm.pan!.toUpperCase()),
                    if ((firm.phone ?? '').isNotEmpty)
                      _metaChip('Phone', firm.phone!),
                    if ((firm.email ?? '').isNotEmpty)
                      _metaChip('Email', firm.email!),
                  ],
                ),
              ],
            ),
          ),
          pw.Container(
            padding:
                const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: pw.BoxDecoration(
              color: PdfColors.white,
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Text(
                  title,
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: style.brandDeep,
                    letterSpacing: 1.6,
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  number,
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: style.ink,
                  ),
                ),
                if (stamp != null) ...[
                  pw.SizedBox(height: 6),
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: pw.BoxDecoration(
                      color: style.brandDeep,
                      borderRadius: pw.BorderRadius.circular(3),
                    ),
                    child: pw.Text(
                      stamp,
                      style: pw.TextStyle(
                        fontSize: 8.4,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.white,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _exists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Logo chip for the header. Returns a spacer when the file exists but can't
  /// be decoded, so layout stays stable either way.
  pw.Widget _logoChip(String path) {
    try {
      final bytes = File(path).readAsBytesSync();
      return pw.Padding(
        padding: const pw.EdgeInsets.only(right: 14),
        child: pw.Container(
          width: 58,
          height: 58,
          padding: const pw.EdgeInsets.all(4),
          decoration: pw.BoxDecoration(
            color: PdfColors.white,
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Image(
            pw.MemoryImage(bytes),
            fit: pw.BoxFit.contain,
          ),
        ),
      );
    } catch (_) {
      return pw.SizedBox(width: 58, height: 58);
    }
  }

  pw.Widget _metaChip(String label, String value) {
    return pw.RichText(
      text: pw.TextSpan(
        children: [
          pw.TextSpan(
            text: '$label: ',
            style: pw.TextStyle(
              fontSize: 8.6,
              color: PdfColors.white,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.TextSpan(
            text: value,
            style: pw.TextStyle(fontSize: 8.6, color: PdfColors.white),
          ),
        ],
      ),
    );
  }

  String _address() {
    final parts = <String>[
      firm.addressLine1 ?? '',
      firm.addressLine2 ?? '',
      [firm.city, firm.pincode].where((e) => e != null && e.isNotEmpty).join(' '),
    ].where((e) => e.trim().isNotEmpty).toList();
    return parts.join(', ');
  }

  /// The two addressee columns, split by a hairline.
  ///
  /// A document with only one addressee (a payment receipt) passes the same
  /// party twice and gets a full-width column, which is what it wants.
  pw.Widget parties(PdfParty left, PdfParty right) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: style.line, width: 0.7),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(child: _partyBlock(left)),
          pw.Container(width: 0.7, color: style.line),
          pw.Expanded(child: _partyBlock(right)),
        ],
      ),
    );
  }

  pw.Widget _partyBlock(PdfParty party) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(10),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            party.label.toUpperCase(),
            style: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              color: style.inkSoft,
              letterSpacing: 1.1,
            ),
          ),
          pw.SizedBox(height: 3),
          pw.Text(
            party.name,
            style: pw.TextStyle(
              fontSize: 11.5,
              fontWeight: pw.FontWeight.bold,
              color: style.ink,
            ),
          ),
          if (party.address != null && party.address!.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              party.address!,
              style:
                  pw.TextStyle(fontSize: 9, color: style.inkSoft, height: 1.45),
            ),
          ],
          if (party.gstin != null && party.gstin!.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              'GSTIN: ${party.gstin!.toUpperCase()}',
              style: pw.TextStyle(fontSize: 9, color: style.inkSoft),
            ),
          ],
          if (party.state != null && party.state!.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              'State: ${party.state}',
              style: pw.TextStyle(fontSize: 9, color: style.inkSoft),
            ),
          ],
        ],
      ),
    );
  }

  // ---- Items -------------------------------------------------------------

  /// The line-item table.
  ///
  /// One `pw.Table` holding every item, which `pw.MultiPage` *does* paginate:
  /// `pw.Table` is a `SpanningWidget`, so an over-tall table is re-laid out
  /// against the space left on the page, its row cursor is handed to the next
  /// page's pass, and it stops once every item is placed. What it does not do is
  /// repeat the column headings, so a continuation sheet used to carry bare
  /// `#`/`HSN`/`Amount` rows under nothing. `repeat: true` on the header row is
  /// what puts the brand-filled heading strip back at the top of every page
  /// after the first.
  pw.Widget itemsTable(
    List<PdfLineItem> items, {
    required bool interState,
    required String secondHead,
  }) {
    return pw.Table(
      border: pw.TableBorder.all(color: style.line, width: 0.7),
      columnWidths: interState
          // IGST branch: #, Item, HSN, Qty, Rate, Taxable, IGST, Amount.
          ? const {
              0: pw.FixedColumnWidth(26),
              1: pw.FlexColumnWidth(3.1),
              2: pw.FixedColumnWidth(52),
              3: pw.FixedColumnWidth(46),
              4: pw.FixedColumnWidth(52),
              5: pw.FixedColumnWidth(58),
              6: pw.FixedColumnWidth(58),
              7: pw.FixedColumnWidth(58),
            }
          // Intra-state: CGST and SGST columns, every index contiguous —
          // an earlier map skipped 6, so Amount drifted out of its column.
          : const {
              0: pw.FixedColumnWidth(26),
              1: pw.FlexColumnWidth(3.1),
              2: pw.FixedColumnWidth(52),
              3: pw.FixedColumnWidth(46),
              4: pw.FixedColumnWidth(52),
              5: pw.FixedColumnWidth(58),
              6: pw.FixedColumnWidth(44),
              7: pw.FixedColumnWidth(44),
              8: pw.FixedColumnWidth(58),
            },
      children: [
        pw.TableRow(
          repeat: true,
          decoration: pw.BoxDecoration(color: style.brand),
          children: [
            _headCell('#'),
            _headCell('Item'),
            _headCell('HSN/SAC'),
            _headCell('Qty'),
            _headCell('Rate'),
            _headCell('Taxable'),
            if (interState)
              _headCell('IGST')
            else ...[
              _headCell('CGST'),
              _headCell(secondHead),
            ],
            _headCell('Amount'),
          ],
        ),
        for (var i = 0; i < items.length; i++)
          pw.TableRow(
            decoration: i.isOdd && style.usesZebraRows
                ? pw.BoxDecoration(color: style.tint)
                : null,
            children: [
              _bodyCell('${i + 1}'),
              _bodyCell(items[i].name, bold: false),
              _bodyCell(items[i].hsn ?? '-'),
              _bodyCell(Formatters.qty(dec(items[i].quantity))),
              _bodyCell(Formatters.money(dec(items[i].rate))),
              _bodyCell(Formatters.money(dec(items[i].taxableValue))),
              if (interState)
                _bodyCell(items[i].igst > 0
                    ? '${Formatters.money(dec(items[i].igst))}\n'
                        '${_rateLabel(items[i].gstRate)}'
                    : '-'),
              if (!interState) ...[
                _bodyCell(items[i].cgst > 0
                    ? '${Formatters.money(dec(items[i].cgst))}\n'
                        '${_rateLabel(items[i].gstRate / 2)}'
                    : '-'),
                _bodyCell(items[i].sgst > 0
                    ? '${Formatters.money(dec(items[i].sgst))}\n'
                        '${_rateLabel(items[i].gstRate / 2)}'
                    : '-'),
              ],
              _bodyCell(Formatters.money(dec(items[i].total)), bold: true),
            ],
          ),
      ],
    );
  }

  pw.Widget _headCell(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 6),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 8.4,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        ),
      ),
    );
  }

  pw.Widget _bodyCell(String text, {bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 8.6,
          color: style.ink,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  String _rateLabel(num rate) {
    // Half-rates of cess-like goods (0.25% -> CGST 0.125%) must not round to
    // a lie: show up to 3 decimals, trimming trailing zeros.
    final s = rate.toStringAsFixed(3);
    final trimmed = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return '${trimmed.isEmpty ? 0 : trimmed}%';
  }

  // ---- Totals ------------------------------------------------------------

  /// The figures block, with the grand total on its own banded row.
  ///
  /// The label is a parameter rather than the word "GRAND TOTAL" because a
  /// purchase bill's bottom line is a liability, not a sale, and a receipt has
  /// no total block at all.
  ///
  /// [afterGrand] prints below the grand-total band. Amount Paid and Balance
  /// Due belong there: they are what has happened *to* the total, not part of
  /// the arithmetic that arrived at it, and a reader scanning the column would
  /// otherwise add them to the subtotal.
  pw.Widget totalsTable(
    List<PdfTotalRow> rows, {
    required String grandLabel,
    required String grandTotal,
    List<PdfTotalRow> afterGrand = const [],
  }) {
    return pw.Table(
      columnWidths: {
        0: const pw.FlexColumnWidth(1),
        1: const pw.FixedColumnWidth(108),
      },
      children: [
        for (final row in rows) _totalRow(row),
        pw.TableRow(
          decoration: pw.BoxDecoration(color: style.accentBand),
          children: [
            pw.Padding(
              padding:
                  const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: pw.Text(
                grandLabel,
                style: pw.TextStyle(
                  fontSize: 10.5,
                  fontWeight: pw.FontWeight.bold,
                  color: style.brandDeep,
                ),
              ),
            ),
            pw.Padding(
              padding:
                  const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: pw.Text(
                grandTotal,
                textAlign: pw.TextAlign.right,
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: style.brandDeep,
                ),
              ),
            ),
          ],
        ),
        for (final row in afterGrand) _totalRow(row),
      ],
    );
  }

  pw.TableRow _totalRow(PdfTotalRow row) => pw.TableRow(
        children: [
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 3),
            child: pw.Text(
              row.label,
              style: pw.TextStyle(
                fontSize: 9.2,
                color: row.emphasize ? style.ink : style.inkSoft,
                fontWeight:
                    row.emphasize ? pw.FontWeight.bold : pw.FontWeight.normal,
              ),
            ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 3),
            child: pw.Text(
              row.value,
              textAlign: pw.TextAlign.right,
              style: pw.TextStyle(
                fontSize: 9.2,
                color: row.emphasize ? style.brandDeep : style.ink,
                fontWeight:
                    row.emphasize ? pw.FontWeight.bold : pw.FontWeight.normal,
              ),
            ),
          ),
        ],
      );

  // ---- Text blocks -------------------------------------------------------

  /// "Amount in words" and its answer, as loose widgets rather than a column.
  ///
  /// Returning a list rather than one `pw.Column` is deliberate: nesting a
  /// column inside the panel's column lays out identically but emits an extra
  /// translate per block, so keeping the children flat is what lets the
  /// refactored sales PDF be compared byte for byte against the old one.
  ///
  /// The caption is a parameter because the sales document has always printed
  /// "Total Invoice Amount (in words)" on the customer's copy, and changing
  /// that is a different decision to making.
  List<pw.Widget> wordsBlock({required String label, required String words}) {
    return [
      pw.Text(
        label,
        style: pw.TextStyle(
          fontSize: 8,
          fontWeight: pw.FontWeight.bold,
          color: style.inkSoft,
          letterSpacing: 0.8,
        ),
      ),
      pw.SizedBox(height: 2),
      pw.Text(
        words,
        style: pw.TextStyle(
          fontSize: 9.6,
          color: style.ink,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
    ];
  }

  /// The firm's own payment details, for the customer to pay by.
  ///
  /// Returns null when the firm has turned the section off or has no account
  /// number — a "Payment Details" heading above nothing reads as a document
  /// that forgot to finish. Loose widgets rather than a column, for the reason
  /// given on [wordsBlock].
  List<pw.Widget>? bankBlock() {
    final showBank = firm.showBankOnInvoice &&
        (firm.bankAccountNumber?.isNotEmpty ?? false);
    if (!showBank) return null;
    return [
      pw.SizedBox(height: 8),
      pw.Divider(color: style.line, height: 1),
      pw.SizedBox(height: 6),
      pw.Text(
        'Payment Details',
        style: pw.TextStyle(
          fontSize: 8,
          fontWeight: pw.FontWeight.bold,
          color: style.inkSoft,
          letterSpacing: 0.8,
        ),
      ),
      pw.SizedBox(height: 3),
      if ((firm.upiId ?? '').isNotEmpty) _payLine('UPI', '${firm.upiId}'),
      if ((firm.bankName ?? '').isNotEmpty) _payLine('Bank', firm.bankName!),
      if ((firm.bankAccountName ?? '').isNotEmpty)
        _payLine('Account Name', firm.bankAccountName!),
      if ((firm.bankAccountNumber ?? '').isNotEmpty)
        _payLine('Account No.', firm.bankAccountNumber!),
      if ((firm.bankIfsc ?? '').isNotEmpty)
        _payLine('IFSC', firm.bankIfsc!.toUpperCase()),
      if ((firm.bankBranch ?? '').isNotEmpty)
        _payLine('Branch', firm.bankBranch!),
    ];
  }

  /// A UPI collect-request QR, captioned with what it will actually charge.
  pw.Widget? upiQrBlock({
    required String amount,
    required String note,
    required String invoiceNumber,
  }) {
    if (!firm.showQrOnInvoice || (firm.upiId ?? '').trim().isEmpty) return null;
    final qr = UpiQr.widget(
      UpiQr.upiUri(
        payeeVpa: firm.upiId!.trim(),
        payeeName: firm.name,
        amount: amount,
        note: note,
        invoiceNumber: invoiceNumber,
      ),
      size: 86,
    );
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        ?qr,
        pw.SizedBox(width: 10),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(height: 4),
              pw.Text(
                'Scan to pay via any UPI app',
                style: pw.TextStyle(
                  fontSize: 8.4,
                  fontWeight: pw.FontWeight.bold,
                  color: style.inkSoft,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                '${firm.upiId} · ₹$amount',
                style: pw.TextStyle(fontSize: 8.2, color: style.inkSoft),
              ),
            ],
          ),
        ),
      ],
    );
  }

  pw.Widget _payLine(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 1.5),
      child: pw.RichText(
        text: pw.TextSpan(
          children: [
            pw.TextSpan(
              text: '$label: ',
              style: pw.TextStyle(
                fontSize: 9,
                color: style.inkSoft,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.TextSpan(
              text: value,
              style: pw.TextStyle(fontSize: 9, color: style.ink),
            ),
          ],
        ),
      ),
    );
  }

  /// A titled block of free text: terms, notes, a deduction explanation.
  pw.Widget? noteBlock(String title, String? body) {
    if (body == null || body.trim().isEmpty) return null;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          title,
          style: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
            color: style.inkSoft,
            letterSpacing: 0.8,
          ),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          body,
          style: pw.TextStyle(fontSize: 8.6, color: style.inkSoft, height: 1.55),
        ),
      ],
    );
  }

  /// The two signature lines at the foot of the page.
  pw.Widget signatureBlock({required String leftCaption}) {
    return pw.Padding(
      padding: pw.EdgeInsets.symmetric(horizontal: style.gutter),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                leftCaption,
                style: pw.TextStyle(fontSize: 8.4, color: style.inkSoft),
              ),
              pw.SizedBox(height: 22),
              pw.Container(
                width: 130,
                decoration: pw.BoxDecoration(
                  border: pw.Border(top: pw.BorderSide(color: style.line)),
                ),
                padding: const pw.EdgeInsets.only(top: 3),
                child: pw.Text(
                  'Receiver\'s Signature',
                  style: pw.TextStyle(fontSize: 8, color: style.inkSoft),
                ),
              ),
            ],
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                'For ${firm.name}',
                style: pw.TextStyle(
                  fontSize: 9.6,
                  fontWeight: pw.FontWeight.bold,
                  color: style.ink,
                ),
              ),
              pw.SizedBox(height: 22),
              pw.Container(
                width: 130,
                alignment: pw.Alignment.topRight,
                decoration: pw.BoxDecoration(
                  border: pw.Border(top: pw.BorderSide(color: style.line)),
                ),
                padding: const pw.EdgeInsets.only(top: 3),
                child: pw.Text(
                  'Authorised Signatory',
                  style: pw.TextStyle(fontSize: 8, color: style.inkSoft),
                  textAlign: pw.TextAlign.right,
                ),
              ),
              if ((firm.signatureName ?? '').isNotEmpty)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 2),
                  child: pw.Text(
                    firm.signatureName!,
                    style: pw.TextStyle(
                        fontSize: 8.4,
                        color: style.ink,
                        fontWeight: pw.FontWeight.bold),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The per-page strip. Repeated on every page by `pw.MultiPage`.
  pw.Widget footer(pw.Context context) {
    return pw.Container(
      decoration: pw.BoxDecoration(color: style.footerBand),
      padding: pw.EdgeInsets.symmetric(horizontal: style.gutter, vertical: 9),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            '${firm.name} • Generated by ${AppConstants.appName}',
            style: pw.TextStyle(fontSize: 7.8, color: style.inkSoft),
          ),
          pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: pw.TextStyle(fontSize: 7.8, color: style.inkSoft),
          ),
        ],
      ),
    );
  }

  /// Horizontal page padding, applied to every block that is not full-bleed.
  pw.EdgeInsets gutterPadding() =>
      pw.EdgeInsets.symmetric(horizontal: style.gutter);
}