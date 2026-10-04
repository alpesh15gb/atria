import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_fonts.dart';
import 'pdf_sections.dart';
import 'pdf_template_style.dart';

import '../database/app_database.dart';
import '../engine/gst_engine.dart';
import '../utils/formatters.dart';
import '../utils/number_words.dart';

/// Renders a GST-compliant Indian invoice/quotation PDF.
///
/// Everything that does not depend on the document being a *sale* — the header
/// band, the party boxes, the items table, the signature line, the footer —
/// lives in [PdfSections], because a purchase bill needs the same furniture
/// and two copies of it would be two places to fix the same bug. What is left
/// here is the sales half: which title a document type prints, which tax
/// columns it has, which figures go in the totals block, and whether there is a
/// balance for the customer to pay.
class InvoicePdf extends PdfSections {
  /// Builds an invoice PDF in the layout [firm] has chosen.
  InvoicePdf.forFirm(FirmEntity firm)
      : super(firm, PdfTemplateStyle.resolve(firm.pdfTemplate));

  static const _docTitles = {
    'invoice': 'TAX INVOICE',
    'quotation': 'QUOTATION',
    'sales_order': 'SALES ORDER',
    'delivery_note': 'DELIVERY NOTE',
    'credit_note': 'CREDIT NOTE',
  };

  /// Prints [invoice] in the firm's layout.
  ///
  /// The entry point every call site uses, so the layout choice reaches all of
  /// them from one place:
  ///
  /// ```dart
  /// InvoicePdf.forFirm(firm).build(invoice: inv, items: lines)
  /// ```
  Future<Uint8List> build({
    required SalesInvoiceEntity invoice,
    required List<SalesInvoiceItemEntity> items,
  }) async {
    // Helvetica has no ₹ (see PdfFonts) — Inter rides along as a fallback.
    final doc = pw.Document(
      pageMode: PdfPageMode.fullscreen,
      theme: await PdfFonts.theme(),
    );
    final isInvoice = invoice.docType == 'invoice' ||
        invoice.docType == 'credit_note' ||
        invoice.docType == 'quotation';

    doc.addPage(
      pw.MultiPage(
        pageFormat: style.pageFormat,
        margin: const pw.EdgeInsets.all(0),
        // A bulk invoice legitimately carries 50+ lines. `MultiPage` defaults
        // to a 20-page ceiling and throws `TooManyPagesException` past it in
        // debug builds; that ceiling is there to catch a runaway layout, not
        // to ration a bill.
        maxPages: 100,
        build: (context) {
          return [
            header(
              title: _docTitles[invoice.docType] ?? 'INVOICE',
              number: invoice.number,
            ),
            pw.Padding(
              padding: gutterPadding(),
              child: parties(_billTo(invoice), _shipTo(invoice)),
            ),
            pw.SizedBox(height: 12),
            pw.Padding(
              padding: gutterPadding(),
              child: itemsTable(
                items.map(PdfLineItem.fromSales).toList(),
                interState: invoice.isInterState,
                secondHead: _secondTaxHead(invoice),
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Padding(
              padding: gutterPadding(),
              child: _totals(invoice),
            ),
            pw.SizedBox(height: 14),
            pw.Padding(
              padding: gutterPadding(),
              child: _wordsAndBank(invoice),
            ),
            if (isInvoice) ...[
              pw.SizedBox(height: 14),
              pw.Padding(
                padding: gutterPadding(),
                child: noteBlock('Terms & Conditions', _terms(invoice)) ??
                    pw.SizedBox(),
              ),
            ],
            pw.SizedBox(height: 24),
            signatureBlock(
              leftCaption: 'Received the above goods in good condition',
            ),
          ];
        },
        footer: footer,
      ),
    );

    return doc.save();
  }

  PdfParty _billTo(SalesInvoiceEntity invoice) => PdfParty(
        label: 'Bill To',
        name: invoice.partyName ?? 'Walk-in Customer',
        address: invoice.billingAddress,
        gstin: invoice.partyGstin,
      );

  PdfParty _shipTo(SalesInvoiceEntity invoice) => PdfParty(
        label: invoice.docType == 'quotation' ? 'Quotation For' : 'Ship To',
        name: invoice.partyName ?? 'Walk-in Customer',
        address: invoice.shippingAddress ?? invoice.billingAddress,
        gstin: invoice.partyGstin,
      );

  /// The name of the second intra-state tax column on this document: UTGST for
  /// a Union Territory, SGST otherwise. Derived from the same state codes the
  /// engine split the tax by, so the column headings and the amounts under them
  /// can never disagree.
  String _secondTaxHead(SalesInvoiceEntity invoice) {
    if (invoice.isInterState) return 'IGST';
    return intraStateSecondHead(
      resolveGstSplit(
        supplierState: firm.stateCode,
        buyerState: invoice.placeOfSupply,
      ),
    );
  }

  pw.Widget _totals(SalesInvoiceEntity invoice) {
    final rows = <PdfTotalRow>[];
    void row(String label, String value) => rows.add(PdfTotalRow(label, value));

    row('Subtotal', Formatters.money(dec(invoice.subTotal)));
    final invoiceDiscount = GstEngine.resolvedInvoiceDiscount(
      subTotal: invoice.subTotal,
      itemDiscount: invoice.itemDiscount,
      invoiceDiscountPercent: invoice.invoiceDiscountPercent,
      invoiceDiscountAmount: invoice.invoiceDiscountAmount,
    );
    if (invoice.itemDiscount.abs() > 0.001 ||
        invoiceDiscount.abs() > 0.001) {
      row('Discount',
          '- ${Formatters.money(dec(invoice.itemDiscount + invoiceDiscount))}');
    }
    if (invoice.shippingCharge.abs() > 0.001) {
      row('Shipping / Freight', Formatters.money(dec(invoice.shippingCharge)));
    }
    row('Taxable Value', Formatters.money(dec(invoice.taxableValue)));
    if (invoice.cgst.abs() > 0.001) {
      row('CGST', Formatters.money(dec(invoice.cgst)));
    }
    if (invoice.sgst.abs() > 0.001) {
      // An inter-state invoice has no SGST, so this row only prints for an
      // intra-state one — where the correct name may be UTGST.
      row(_secondTaxHead(invoice), Formatters.money(dec(invoice.sgst)));
    }
    if (invoice.igst.abs() > 0.001) {
      row('IGST', Formatters.money(dec(invoice.igst)));
    }
    if (invoice.cess.abs() > 0.001) {
      row('Cess', Formatters.money(dec(invoice.cess)));
    }
    // Tax collected at source sits between the tax and the round-off, because
    // that is the order the invoice value is built in: tax on the goods, then
    // TCS on the consideration, then a round to the rupee.
    if (invoice.tcs.abs() > 0.001) {
      row(
        invoice.tcsRate > 0
            ? 'TCS @ ${Formatters.percent(invoice.tcsRate)}'
            : 'TCS',
        Formatters.money(dec(invoice.tcs)),
      );
    }
    if (invoice.roundOff.abs() > 0.001) {
      row('Round Off',
          '${invoice.roundOff < 0 ? '-' : ''}${Formatters.money(dec(invoice.roundOff.abs()))}');
    }

    return totalsTable(
      rows,
      grandLabel: 'GRAND TOTAL',
      grandTotal: Formatters.money(dec(invoice.grandTotal)),
    );
  }

  pw.Widget _wordsAndBank(SalesInvoiceEntity invoice) {
    final words =
        NumberToWords.indianCurrency(invoice.grandTotal, prefix: 'Rupees');
    // Only invoices (not quotes) get the collect-request QR — a quotation is
    // not yet payable, and a QR on it invites payment before there is a bill.
    final isCollectable = invoice.docType == 'invoice';
    final amount = invoice.grandTotal.toStringAsFixed(2);
    final qr = isCollectable
        ? upiQrBlock(
            amount: amount,
            note: 'Invoice ${invoice.number}',
            invoiceNumber: invoice.number,
          )
        : null;
    final bank = isCollectable ? bankBlock() : null;

    return panelOf([
      ...wordsBlock(label: 'Total Invoice Amount (in words)', words: words),
      ...?bank,
      if (qr != null) ...[
        pw.SizedBox(height: 6),
        qr,
      ],
    ]);
  }

  String? _terms(SalesInvoiceEntity invoice) {
    if (invoice.docType == 'quotation') {
      return invoice.terms ?? firm.invoiceTerms;
    }
    return invoice.terms ??
        firm.invoiceTerms ??
        // Never promise a legal term the seller didn't choose — the old
        // fallback invented an 18% p.a. interest clause on every invoice.
        'Goods once sold will not be taken back. All disputes subject to local jurisdiction.';
  }
}