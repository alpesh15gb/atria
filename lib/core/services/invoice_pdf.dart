import '../domain/gst_registration.dart';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_fonts.dart';
import 'pdf_sections.dart';
import 'pdf_template_style.dart';
import 'reference_document_pdf.dart';

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
  InvoicePdf._(super.firm, super.style);

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
    final selected = DocumentTemplates.parse(firm.pdfTemplate).forDocument(invoice.docType == 'quotation' ? 'quotation' : 'invoice');
    if (selected.isReference) {
      return ReferenceDocumentPdf(firm, selected).build(ReferenceDocument.sale(firm, invoice, items));
    }
    if (selected.id != style.id) return InvoicePdf._(firm, selected).build(invoice: invoice, items: items);
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
              title: invoice.docType == 'invoice' && !firm.isGstRegistered &&
                  invoice.cgst + invoice.sgst + invoice.igst + invoice.cess == 0
                  ? 'INVOICE' : _docTitles[invoice.docType] ?? 'INVOICE',
              number: invoice.number,
              stamp: isInvoice ? _stamp(invoice) : null,
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
                showTax: firm.isGstRegistered || invoice.cgst + invoice.sgst + invoice.igst + invoice.cess > 0,
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
    row(firm.isGstRegistered || invoice.cgst + invoice.sgst + invoice.igst + invoice.cess > 0 ? 'Taxable Value' : 'Net Amount', Formatters.money(dec(invoice.taxableValue)));
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
      afterGrand: _settlement(invoice),
    );
  }

  /// Only an invoice carries a balance. A quotation, an order and a delivery
  /// note are all stored with `DocumentSettlement.settled` — a ₹0 balance and a
  /// `paid` status — because the bill raised against them is the payable one.
  /// Printing their settlement would read as "Amount Paid ₹0.00, Balance Due
  /// ₹0.00" next to a grand total of ₹2,000, which is a different wrong.
  bool _isCollectable(SalesInvoiceEntity invoice) =>
      invoice.docType == 'invoice';

  /// What the UPI QR on this document should ask for, or null when it should not
  /// carry one at all.
  ///
  /// The QR asks for what is *owed*, not what the invoice was worth. It used to
  /// encode the grand total, so a customer paying off the last ₹2,000 of a
  /// ₹5,000 bill scanned a request for the full ₹5,000 — and paying it meant
  /// handing over the money twice or getting change back, neither of which
  /// reads as the app's fault at the counter.
  ///
  /// Public and named because the amount encoded in a QR that is drawn as a
  /// grid of rectangles cannot be asserted on from the finished file; the
  /// decision, not the raster, is what has to be right.
  String? collectableAmount(SalesInvoiceEntity invoice) {
    if (!_isCollectable(invoice)) return null;
    if (invoice.balanceDue <= 0.001) return null;
    return invoice.balanceDue.toStringAsFixed(2);
  }

  /// What has been settled against the invoice, printed under the grand total.
  ///
  /// The balance prints whenever there is one, even when it equals the grand
  /// total: "Balance Due ₹5,000" is the line the customer is looking for.
  /// "Amount Paid ₹0.00" against nothing is noise dressed as information, so
  /// it stays off. A settled invoice prints neither and says so in the header
  /// stamp instead.
  List<PdfTotalRow> _settlement(SalesInvoiceEntity invoice) {
    if (!_isCollectable(invoice)) return const [];
    // A cancelled invoice's balance is zeroed by the cancel path so ageing
    // stops counting it — that is a bookkeeping fact, not a settlement, and
    // must not print as one.
    if (invoice.status == 'cancelled') return const [];

    final rows = <PdfTotalRow>[];
    if (invoice.paidAmount.abs() > 0.001) {
      rows.add(
          PdfTotalRow('Amount Paid', Formatters.money(dec(invoice.paidAmount))));
    }
    if (invoice.balanceDue > 0.001) {
      rows.add(PdfTotalRow(
        'Balance Due',
        Formatters.money(dec(invoice.balanceDue)),
        emphasize: true,
      ));
    }
    return rows;
  }

  /// The one badge this document earns.
  String? _stamp(SalesInvoiceEntity invoice) {
    if (!_isCollectable(invoice)) return null;
    if (invoice.status == 'cancelled') return 'CANCELLED';
    // Money must actually have arrived. A zero-total invoice balances itself
    // without being paid, and calling that PAID IN FULL would be a lie about a
    // document nobody sent money against.
    if (invoice.paidAmount <= 0.001) return null;
    if (invoice.balanceDue > 0.001) return null;
    return 'PAID IN FULL';
  }

  pw.Widget _wordsAndBank(SalesInvoiceEntity invoice) {
    final words =
        NumberToWords.indianCurrency(invoice.grandTotal, prefix: 'Rupees');
    // Only invoices (not quotes) get the collect-request QR — a quotation is
    // not yet payable, and a QR on it invites payment before there is a bill.
    final isCollectable = _isCollectable(invoice);
    // The QR asks for what is *owed*, not what the invoice was worth — see
    // [collectableAmount].
    final amount = collectableAmount(invoice);
    final qr = amount != null
        ? upiQrBlock(
            amount: amount,
            note: 'Invoice ${invoice.number}',
            invoiceNumber: invoice.number,
          )
        : null;
    // The bank details are the other half of "here is how to pay", so they go
    // when the QR does: a settled invoice asking for a transfer is an invoice
    // with a payment instruction on a document that is already paid.
    final bank = isCollectable && amount != null ? bankBlock() : null;

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
