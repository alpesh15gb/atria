import 'dart:io';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../constants/app_constants.dart';
import '../database/app_database.dart';
import '../engine/gst_engine.dart';
import '../utils/formatters.dart';
import '../utils/number_words.dart';
import 'upi_qr.dart';

/// Renders a GST-compliant Indian invoice/quotation PDF.
class InvoicePdf {
  InvoicePdf._();

  static const PdfColor _brand = PdfColor.fromInt(0xFF1D4ED8);
  static const PdfColor _brandDeep = PdfColor.fromInt(0xFF1E3A8A);
  static const PdfColor _ink = PdfColor.fromInt(0xFF161A18);
  static const PdfColor _inkSoft = PdfColor.fromInt(0xFF5A605C);
  static const PdfColor _line = PdfColor.fromInt(0xFFD8D5CD);
  static const PdfColor _tint = PdfColor.fromInt(0xFFF3F6F5);

  static const _docTitles = {
    'invoice': 'TAX INVOICE',
    'quotation': 'QUOTATION',
    'sales_order': 'SALES ORDER',
    'delivery_note': 'DELIVERY NOTE',
    'credit_note': 'CREDIT NOTE',
  };

  static Future<Uint8List> build({
    required SalesInvoiceEntity invoice,
    required List<SalesInvoiceItemEntity> items,
    required FirmEntity firm,
  }) async {
    final doc = pw.Document(pageMode: PdfPageMode.fullscreen);
    final isInvoice = invoice.docType == 'invoice' ||
        invoice.docType == 'credit_note' ||
        invoice.docType == 'quotation';

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(0),
        build: (context) {
          return [
            _header(firm, invoice),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 34),
              child: _parties(firm, invoice),
            ),
            pw.SizedBox(height: 12),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 34),
              child: _itemsTable(items, invoice),
            ),
            pw.SizedBox(height: 10),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 34),
              child: _totals(firm, invoice),
            ),
            pw.SizedBox(height: 14),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 34),
              child: _wordsAndBank(firm, invoice),
            ),
            if (isInvoice) ...[
              pw.SizedBox(height: 14),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 34),
                child: _terms(firm, invoice),
              ),
            ],
            pw.SizedBox(height: 24),
            _signature(firm),
          ];
        },
        footer: (context) => _footer(context, firm, invoice),
      ),
    );

    return doc.save();
  }

  /// Logo chip for the header. Returns a spacer when the file exists but
  /// can't be decoded, so layout stays stable either way.
  static pw.Widget _logoFromFile(String path) {
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

  static pw.Widget _header(FirmEntity firm, SalesInvoiceEntity invoice) {
    final title = _docTitles[invoice.docType] ?? 'INVOICE';
    return pw.Container(
      decoration: const pw.BoxDecoration(
        gradient: pw.LinearGradient(
          begin: pw.Alignment.topLeft,
          end: pw.Alignment.bottomRight,
          colors: [_brand, _brandDeep],
        ),
      ),
      padding: const pw.EdgeInsets.fromLTRB(34, 20, 34, 20),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // Firm logo, when one is set in Firm Profile. Read at build time
          // from logoPath; a missing/corrupt file degrades to the text-only
          // header instead of failing the whole PDF.
          if ((firm.logoPath ?? '').isNotEmpty &&
              File(firm.logoPath!).existsSync())
            _logoFromFile(firm.logoPath!),
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
                if (firm.addressLine1 != null &&
                    firm.addressLine1!.isNotEmpty) ...[
                  pw.Text(
                    _address(firm),
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
                    if (firm.gstin != null && firm.gstin!.isNotEmpty)
                      _metaChip('GSTIN', firm.gstin!.toUpperCase()),
                    if (firm.pan != null && firm.pan!.isNotEmpty)
                      _metaChip('PAN', firm.pan!.toUpperCase()),
                    if (firm.phone != null && firm.phone!.isNotEmpty)
                      _metaChip('Phone', firm.phone!),
                    if (firm.email != null && firm.email!.isNotEmpty)
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
                    color: _brandDeep,
                    letterSpacing: 1.6,
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  invoice.number,
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: _ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _metaChip(String label, String value) {
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

  static String _address(FirmEntity firm) {
    final parts = <String>[
      firm.addressLine1 ?? '',
      firm.addressLine2 ?? '',
      [firm.city, firm.pincode].where((e) => e != null && e.isNotEmpty).join(' '),
    ].where((e) => e.trim().isNotEmpty).toList();
    return parts.join(', ');
  }

  static pw.Widget _parties(FirmEntity firm, SalesInvoiceEntity invoice) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _line, width: 0.7),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: _partyBlock(
              'Bill To',
              invoice.partyName ?? 'Walk-in Customer',
              invoice.billingAddress,
              invoice.partyGstin,
              null,
            ),
          ),
          pw.Container(width: 0.7, color: _line),
          pw.Expanded(
            child: _partyBlock(
              invoice.docType == 'quotation' ? 'Quotation For' : 'Ship To',
              invoice.partyName ?? 'Walk-in Customer',
              invoice.shippingAddress ?? invoice.billingAddress,
              invoice.partyGstin,
              null,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _partyBlock(
    String label,
    String name,
    String? address,
    String? gstin,
    String? state,
  ) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(10),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            label.toUpperCase(),
            style: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              color: _inkSoft,
              letterSpacing: 1.1,
            ),
          ),
          pw.SizedBox(height: 3),
          pw.Text(
            name,
            style: pw.TextStyle(
              fontSize: 11.5,
              fontWeight: pw.FontWeight.bold,
              color: _ink,
            ),
          ),
          if (address != null && address.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              address,
              style: pw.TextStyle(fontSize: 9, color: _inkSoft, height: 1.45),
            ),
          ],
          if (gstin != null && gstin.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              'GSTIN: ${gstin.toUpperCase()}',
              style: pw.TextStyle(fontSize: 9, color: _inkSoft),
            ),
          ],
          if (state != null && state.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              'State: $state',
              style: pw.TextStyle(fontSize: 9, color: _inkSoft),
            ),
          ],
        ],
      ),
    );
  }

  static pw.Widget _itemsTable(
      List<SalesInvoiceItemEntity> items, SalesInvoiceEntity invoice) {
    // IGST vs CGST/SGST must match the ENGINE's decision, which keys purely
    // off isInterState. The old `&& hasGstin` extra condition printed '-'
    // in the CGST/SGST columns of inter-state bills to unregistered buyers
    // while the totals still carried IGST — a document that doesn't add up.
    final interState = invoice.isInterState;

    return pw.Table(
      border: pw.TableBorder.all(color: _line, width: 0.7),
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
          // the old map skipped 6, so Amount drifted out of its column.
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
          decoration: const pw.BoxDecoration(color: _brand),
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
              _headCell('SGST'),
            ],
            _headCell('Amount'),
          ],
        ),
        for (var i = 0; i < items.length; i++)
          pw.TableRow(
            decoration:
                i.isOdd ? const pw.BoxDecoration(color: _tint) : null,
            children: [
              _bodyCell('${i + 1}'),
              _bodyCell(items[i].name, bold: false),
              _bodyCell(items[i].hsn ?? '-'),
              _bodyCell(Formatters.qty(
                  _dec(items[i].quantity))),
              _bodyCell(Formatters.money(_dec(items[i].rate))),
              _bodyCell(Formatters.money(_dec(items[i].taxableValue))),
              if (interState)
                _bodyCell(items[i].igst > 0
                    ? '${Formatters.money(_dec(items[i].igst))}\n'
                        '${_rateLabel(items[i].gstRate)}'
                    : '-'),
              if (!interState) ...[
                _bodyCell(items[i].cgst > 0
                    ? '${Formatters.money(_dec(items[i].cgst))}\n'
                        '${_rateLabel(items[i].gstRate / 2)}'
                    : '-'),
                _bodyCell(items[i].sgst > 0
                    ? '${Formatters.money(_dec(items[i].sgst))}\n'
                        '${_rateLabel(items[i].gstRate / 2)}'
                    : '-'),
              ],
              _bodyCell(Formatters.money(_dec(items[i].total)),
                  bold: true),
            ],
          ),
      ],
    );
  }

  static pw.Widget _headCell(String text) {
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

  static pw.Widget _bodyCell(String text, {bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 8.6,
          color: _ink,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  static String _rateLabel(num rate) {
    // Half-rates of cess-like goods (0.25% → CGST 0.125%) must not round to
    // a lie: show up to 3 decimals, trimming trailing zeros.
    final s = rate.toStringAsFixed(3);
    final trimmed = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return '${trimmed.isEmpty ? 0 : trimmed}%';
  }

  static pw.Widget _totals(FirmEntity firm, SalesInvoiceEntity invoice) {
    final rows = <pw.TableRow>[];
    void row(String label, String value, {bool emphasize = false}) {
      rows.add(pw.TableRow(
        children: [
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 3),
            child: pw.Text(
              label,
              style: pw.TextStyle(
                fontSize: 9.2,
                color: emphasize ? _ink : _inkSoft,
                fontWeight:
                    emphasize ? pw.FontWeight.bold : pw.FontWeight.normal,
              ),
            ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 3),
            child: pw.Text(
              value,
              textAlign: pw.TextAlign.right,
              style: pw.TextStyle(
                fontSize: 9.2,
                color: emphasize ? _brandDeep : _ink,
                fontWeight:
                    emphasize ? pw.FontWeight.bold : pw.FontWeight.normal,
              ),
            ),
          ),
        ],
      ));
    }

    row('Subtotal', Formatters.money(_dec(invoice.subTotal)));
    final invoiceDiscount = GstEngine.resolvedInvoiceDiscount(
      subTotal: invoice.subTotal,
      itemDiscount: invoice.itemDiscount,
      invoiceDiscountPercent: invoice.invoiceDiscountPercent,
      invoiceDiscountAmount: invoice.invoiceDiscountAmount,
    );
    if (invoice.itemDiscount.abs() > 0.001 ||
        invoiceDiscount.abs() > 0.001) {
      row('Discount',
          '- ${Formatters.money(_dec(invoice.itemDiscount + invoiceDiscount))}');
    }
    if (invoice.shippingCharge.abs() > 0.001) {
      row('Shipping / Freight', Formatters.money(_dec(invoice.shippingCharge)));
    }
    row('Taxable Value', Formatters.money(_dec(invoice.taxableValue)));
    if (invoice.cgst.abs() > 0.001) {
      row('CGST', Formatters.money(_dec(invoice.cgst)));
    }
    if (invoice.sgst.abs() > 0.001) {
      row('SGST', Formatters.money(_dec(invoice.sgst)));
    }
    if (invoice.igst.abs() > 0.001) {
      row('IGST', Formatters.money(_dec(invoice.igst)));
    }
    if (invoice.cess.abs() > 0.001) {
      row('Cess', Formatters.money(_dec(invoice.cess)));
    }
    if (invoice.roundOff.abs() > 0.001) {
      row('Round Off',
          '${invoice.roundOff < 0 ? '-' : ''}${Formatters.money(_dec(invoice.roundOff.abs()))}');
    }

    return pw.Table(
      columnWidths: {
        0: const pw.FlexColumnWidth(1),
        1: const pw.FixedColumnWidth(108),
      },
      children: [
        ...rows,
        pw.TableRow(
          decoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xFFE6F4F1),
          ),
          children: [
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(
                  horizontal: 8, vertical: 7),
              child: pw.Text(
                'GRAND TOTAL',
                style: pw.TextStyle(
                  fontSize: 10.5,
                  fontWeight: pw.FontWeight.bold,
                  color: _brandDeep,
                ),
              ),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(
                  horizontal: 8, vertical: 7),
              child: pw.Text(
                Formatters.money(_dec(invoice.grandTotal)),
                textAlign: pw.TextAlign.right,
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: _brandDeep,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static pw.Widget _wordsAndBank(FirmEntity firm, SalesInvoiceEntity invoice) {
    final words =
        NumberToWords.indianCurrency(invoice.grandTotal, prefix: 'Rupees');
    final showBank = firm.showBankOnInvoice &&
        (firm.bankAccountNumber?.isNotEmpty ?? false);
    // The showQrOnInvoice toggle existed but did nothing — the UPI id printed
    // as plain text with nothing to scan. Only invoices (not quotes) get the
    // collect-request QR.
    final upiQr = firm.showQrOnInvoice &&
            invoice.docType == 'invoice' &&
            (firm.upiId ?? '').trim().isNotEmpty
        ? UpiQr.widget(
            UpiQr.upiUri(
              payeeVpa: firm.upiId!.trim(),
              payeeName: firm.name,
              amount: invoice.grandTotal.toStringAsFixed(2),
              note: 'Invoice ${invoice.number}',
              invoiceNumber: invoice.number,
            ),
            size: 86,
          )
        : null;

    return pw.Container(
      width: double.infinity,
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _line, width: 0.7),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      padding: const pw.EdgeInsets.all(10),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'Total Invoice Amount (in words)',
            style: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              color: _inkSoft,
              letterSpacing: 0.8,
            ),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            words,
            style: pw.TextStyle(
              fontSize: 9.6,
              color: _ink,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          if (showBank) ...[
            pw.SizedBox(height: 8),
            pw.Divider(color: _line, height: 1),
            pw.SizedBox(height: 6),
            pw.Text(
              'Payment Details',
              style: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: _inkSoft,
                letterSpacing: 0.8,
              ),
            ),
            pw.SizedBox(height: 3),
            if ((firm.upiId ?? '').isNotEmpty)
              _payLine('UPI', '${firm.upiId}'),
            if ((firm.bankName ?? '').isNotEmpty)
              _payLine('Bank', firm.bankName!),
            if ((firm.bankAccountName ?? '').isNotEmpty)
              _payLine('Account Name', firm.bankAccountName!),
            if ((firm.bankAccountNumber ?? '').isNotEmpty)
              _payLine('Account No.', firm.bankAccountNumber!),
            if ((firm.bankIfsc ?? '').isNotEmpty)
              _payLine('IFSC', firm.bankIfsc!.toUpperCase()),
            if ((firm.bankBranch ?? '').isNotEmpty)
              _payLine('Branch', firm.bankBranch!),
          ],
          if (upiQr != null) ...[
            pw.SizedBox(height: 6),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                upiQr,
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
                          color: _inkSoft,
                        ),
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        '${firm.upiId} · ₹${invoice.grandTotal.toStringAsFixed(2)}',
                        style: pw.TextStyle(fontSize: 8.2, color: _inkSoft),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static pw.Widget _payLine(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 1.5),
      child: pw.RichText(
        text: pw.TextSpan(
          children: [
            pw.TextSpan(
              text: '$label: ',
              style: pw.TextStyle(
                fontSize: 9,
                color: _inkSoft,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.TextSpan(
              text: value,
              style: pw.TextStyle(fontSize: 9, color: _ink),
            ),
          ],
        ),
      ),
    );
  }

  static pw.Widget _terms(FirmEntity firm, SalesInvoiceEntity invoice) {
    final terms = invoice.docType == 'quotation'
        ? (invoice.terms ?? firm.invoiceTerms)
        : (invoice.terms ??
            firm.invoiceTerms ??
            // Never promise a legal term the seller didn't choose — the old
            // fallback invented an 18% p.a. interest clause on every invoice.
            'Goods once sold will not be taken back. All disputes subject to local jurisdiction.');
    if (terms == null || terms.trim().isEmpty) return pw.SizedBox();
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Terms & Conditions',
          style: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
            color: _inkSoft,
            letterSpacing: 0.8,
          ),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          terms,
          style: pw.TextStyle(fontSize: 8.6, color: _inkSoft, height: 1.55),
        ),
      ],
    );
  }

  static pw.Widget _signature(FirmEntity firm) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 34),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Received the above goods in good condition',
                style: pw.TextStyle(fontSize: 8.4, color: _inkSoft),
              ),
              pw.SizedBox(height: 22),
              pw.Container(
                width: 130,
                decoration: pw.BoxDecoration(
                  border: pw.Border(top: pw.BorderSide(color: _line)),
                ),
                padding: const pw.EdgeInsets.only(top: 3),
                child: pw.Text(
                  'Receiver\'s Signature',
                  style: pw.TextStyle(fontSize: 8, color: _inkSoft),
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
                  color: _ink,
                ),
              ),
              pw.SizedBox(height: 22),
              pw.Container(
                width: 130,
                alignment: pw.Alignment.topRight,
                decoration: pw.BoxDecoration(
                  border: pw.Border(top: pw.BorderSide(color: _line)),
                ),
                padding: const pw.EdgeInsets.only(top: 3),
                child: pw.Text(
                  'Authorised Signatory',
                  style: pw.TextStyle(fontSize: 8, color: _inkSoft),
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
                        color: _ink,
                        fontWeight: pw.FontWeight.bold),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _footer(
      pw.Context context, FirmEntity firm, SalesInvoiceEntity invoice) {
    return pw.Container(
      decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEFF3F2)),
      padding: const pw.EdgeInsets.symmetric(horizontal: 34, vertical: 9),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            '${firm.name} • Generated by ${AppConstants.appName}',
            style: pw.TextStyle(fontSize: 7.8, color: _inkSoft),
          ),
          pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: pw.TextStyle(fontSize: 7.8, color: _inkSoft),
          ),
        ],
      ),
    );
  }

  /// Database columns are `REAL`; the formatters want exact [Decimal]s.
  static Decimal _dec(num value) => Decimal.parse(value.toString());
}
