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

/// Renders the purchase-side documents: bills, purchase orders, debit notes and
/// payment vouchers.
///
/// These were the documents the app could not print at all. A purchase bill is
/// a tax document with real consequences — it is what input credit is claimed
/// against, and in reverse charge it is the evidence that the supplier owes the
/// tax — and it had no way to leave the phone.
///
/// The furniture all comes from [PdfSections], the same place the sales invoice
/// gets it. What differs is real and is handled here rather than papered over:
///
/// - **The party roles invert.** On a sale the firm supplies and the customer
///   buys, so the tax split reads `supplierState: firm`. On a purchase the firm
///   *buys from* the party, so it reads `supplierState: the bill's place of
///   supply`, `buyerState: firm`. Copying the sales version would print the
///   wrong state-pair and could label SGST where UTGST belongs.
/// - **TDS is a deduction.** The firm withholds it, so it is subtracted and the
///   grand total is what is actually payable to the supplier. TCS on a sale is
///   added, and the two are not the same line.
/// - **There is nothing to collect.** No UPI QR: the shop is the one paying.
class PurchasePdf extends PdfSections {
  PurchasePdf.forFirm(FirmEntity firm)
      : super(firm, PdfTemplateStyle.resolve(firm.pdfTemplate));
  PurchasePdf._(super.firm, super.style);

  static const _docTitles = {
    'bill': 'PURCHASE BILL',
    'purchase_order': 'PURCHASE ORDER',
    'debit_note': 'DEBIT NOTE',
  };

  /// Prints a purchase bill, order or debit note.
  Future<Uint8List> build({
    required PurchaseBillEntity bill,
    required List<PurchaseBillItemEntity> items,
  }) async {
    final selected = DocumentTemplates.parse(firm.pdfTemplate).forDocument('purchase');
    if (selected.isReference) {
      return ReferenceDocumentPdf(firm, selected).build(ReferenceDocument.purchaseBill(firm, bill, items));
    }
    if (selected.id != style.id) return PurchasePdf._(firm, selected).build(bill: bill, items: items);
    final doc = pw.Document(
      pageMode: PdfPageMode.fullscreen,
      theme: await PdfFonts.theme(),
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: style.pageFormat,
        margin: const pw.EdgeInsets.all(0),
        // A monthly bill from a distributor is routinely 200+ lines.
        maxPages: 100,
        build: (context) {
          final compliance = _complianceNotes(bill);
          return [
            header(
              title: _docTitles[bill.docType] ?? 'PURCHASE BILL',
              number: bill.number,
              stamp: bill.docType == 'bill' ? _stamp(bill) : null,
            ),
            pw.Padding(
              padding: gutterPadding(),
              child: parties(_supplier(bill), _details(bill)),
            ),
            pw.SizedBox(height: 12),
            pw.Padding(
              padding: gutterPadding(),
              child: itemsTable(
                items.map(PdfLineItem.fromPurchase).toList(),
                interState: bill.isInterState,
                secondHead: _secondTaxHead(bill),
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Padding(
              padding: gutterPadding(),
              child: _totals(bill),
            ),
            for (final note in compliance) ...[
              pw.SizedBox(height: 10),
              pw.Padding(padding: gutterPadding(), child: note),
            ],
            pw.SizedBox(height: 14),
            pw.Padding(
              padding: gutterPadding(),
              child: panelOf(
                wordsBlock(
                  label: 'Amount payable (in words)',
                  words: NumberToWords.indianCurrency(
                    bill.grandTotal,
                    prefix: 'Rupees',
                  ),
                ),
              ),
            ),
            if ((bill.notes ?? '').trim().isNotEmpty) ...[
              pw.SizedBox(height: 14),
              pw.Padding(
                padding: gutterPadding(),
                child: noteBlock('Notes', bill.notes)!,
              ),
            ],
            pw.SizedBox(height: 24),
            signatureBlock(leftCaption: 'Received the above goods'),
          ];
        },
        footer: footer,
      ),
    );

    return doc.save();
  }

  /// The voucher for money actually paid or received.
  ///
  /// Separate from [build] because it has no lines: what it prints is a set of
  /// particulars and one figure. Splitting it out also stops a payment receipt
  /// growing line-item columns it would have to fake.
  Future<Uint8List> buildVoucher({
    required PaymentEntity payment,
  }) async {
    final doc = pw.Document(
      pageMode: PdfPageMode.fullscreen,
      theme: await PdfFonts.theme(),
    );
    final moneyOut = payment.type == 'payment_out';

    doc.addPage(
      pw.MultiPage(
        pageFormat: style.pageFormat,
        margin: const pw.EdgeInsets.all(0),
        maxPages: 4,
        build: (context) {
          final particulars = <String>[
            'Date: ${Formatters.date(payment.date)}',
            'Particulars: ${moneyOut ? 'Paid to' : 'Received from'}',
            'Mode: ${_modeLabel(payment)}',
            if ((payment.reference ?? '').trim().isNotEmpty)
              '${_referenceLabel(payment)}: ${payment.reference}',
            if ((payment.chequeStatus ?? '').isNotEmpty)
              'Cheque status: ${_chequeStatus(payment)}',
            if (payment.clearanceDate != null)
              'Cleared on: ${Formatters.date(payment.clearanceDate)}',
            if ((payment.linkedInvoiceNumber ?? '').trim().isNotEmpty)
              'Against: ${payment.linkedInvoiceNumber}',
            if ((payment.bankAccount ?? '').trim().isNotEmpty)
              'Account: ${payment.bankAccount}',
          ];

          return [
            header(
              title: moneyOut ? 'PAYMENT VOUCHER' : 'RECEIPT VOUCHER',
              number: payment.number,
            ),
            pw.Padding(
              padding: gutterPadding(),
              child: parties(
                PdfParty(
                  label: moneyOut ? 'Paid To' : 'Received From',
                  name: payment.partyName ?? 'Cash',
                  gstin: payment.partyGstin,
                ),
                _detailsParty(
                  moneyOut ? 'Voucher Details' : 'Receipt Details',
                  '${moneyOut ? 'Paid' : 'Received'} '
                      '${Formatters.money(dec(payment.amount))}',
                  particulars,
                ),
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Padding(
              padding: gutterPadding(),
              child: totalsTable(
                const [],
                grandLabel: moneyOut ? 'AMOUNT PAID' : 'AMOUNT RECEIVED',
                grandTotal: Formatters.money(dec(payment.amount)),
              ),
            ),
            pw.SizedBox(height: 14),
            pw.Padding(
              padding: gutterPadding(),
              child: panelOf(
                wordsBlock(
                  label: 'Amount in words',
                  words: NumberToWords.indianCurrency(
                    payment.amount,
                    prefix: 'Rupees',
                  ),
                ),
              ),
            ),
            if ((payment.bounceReason ?? '').trim().isNotEmpty) ...[
              pw.SizedBox(height: 14),
              pw.Padding(
                padding: gutterPadding(),
                child: noteBlock('Reason for return', payment.bounceReason)!,
              ),
            ],
            if ((payment.notes ?? '').trim().isNotEmpty) ...[
              pw.SizedBox(height: 14),
              pw.Padding(
                padding: gutterPadding(),
                child: noteBlock('Notes', payment.notes)!,
              ),
            ],
            pw.SizedBox(height: 24),
            signatureBlock(
              leftCaption:
                  moneyOut ? 'Paid by' : 'Received by',
            ),
          ];
        },
        footer: footer,
      ),
    );

    return doc.save();
  }

  // ---- Parties -----------------------------------------------------------

  PdfParty _supplier(PurchaseBillEntity bill) => PdfParty(
        label: bill.docType == 'purchase_order' ? 'Ordered From' : 'Supplier',
        name: bill.partyName ?? 'Unnamed Supplier',
        address: bill.billingAddress,
        gstin: bill.partyGstin,
      );

  /// The right-hand column carries what happened to the document rather than
  /// who it is about: the supplier's own invoice number, the dates, and
  /// whether the money has moved.
  PdfParty _details(PurchaseBillEntity bill) {
    final isOrder = bill.docType == 'purchase_order';
    final lines = <String>[
      'Dated ${Formatters.date(bill.billDate)}',
      if (bill.dueDate != null) 'Due ${Formatters.date(bill.dueDate)}',
      if ((bill.createdBy ?? '').trim().isNotEmpty)
        'Entered by ${bill.createdBy}',
    ];
    if (isOrder) {
      lines.add('Status: ${_titleCase(bill.status)}');
    } else {
      lines.add('Payment: ${_titleCase(bill.paymentStatus)}');
      if (bill.paidAmount.abs() > 0.001) {
        lines.add('Paid ${Formatters.money(dec(bill.paidAmount))}');
      }
    }
    return _detailsParty(
      isOrder ? 'Order Details' : 'Bill Details',
      (bill.supplierInvoiceNumber ?? '').trim().isEmpty
          ? (isOrder ? 'Purchase Order' : 'Purchase Bill')
          : 'Supplier Inv. ${bill.supplierInvoiceNumber}',
      lines,
    );
  }

  PdfParty _detailsParty(
          String label, String headline, List<String> lines) =>
      PdfParty(
        label: label,
        name: headline,
        address: lines.isEmpty ? null : lines.join('\n'),
      );

  String _titleCase(String value) {
    if (value.isEmpty) return value;
    return value[0].toUpperCase() + value.substring(1);
  }

  /// A purchase order is never paid — the bill raised against it is. So the
  /// stamp belongs to bills only, and only once money has actually gone out.
  String? _stamp(PurchaseBillEntity bill) {
    if (bill.status == 'cancelled') return 'CANCELLED';
    if (bill.paidAmount <= 0.001) return null;
    if (bill.balanceDue > 0.001) return null;
    return 'PAID IN FULL';
  }

  // ---- Tax ---------------------------------------------------------------

  /// The second intra-state tax column, resolved for a *purchase*.
  ///
  /// Mirrors the engine's decision rather than the sales document's: on a sale
  /// the firm is the supplier, here it is the buyer, so the two states swap
  /// sides. `placeOfSupply` on a purchase bill is the supplier's state code —
  /// that is what `purchase_editor_screen.dart` writes into it.
  ///
  /// [PurchaseBillEntity.isInterState] decides first because that is what the
  /// repository actually charged by. Where the stored state codes disagree with
  /// it — a bill imported from a supplier whose own idea of the place of supply
  /// does not match — the heading follows the arithmetic on the document rather
  /// than re-deciding the split, because a heading that contradicts the figures
  /// under it is worse than a heading that is merely conservative.
  String _secondTaxHead(PurchaseBillEntity bill) {
    if (bill.isInterState) return 'IGST';
    final supplier = bill.placeOfSupply;
    final buyer = firm.stateCode;
    if (supplier == null ||
        buyer == null ||
        supplier.isEmpty ||
        buyer.isEmpty ||
        supplier != buyer) {
      return 'SGST';
    }
    return intraStateSecondHead(
      resolveGstSplit(supplierState: supplier, buyerState: buyer),
    );
  }

  // ---- Totals ------------------------------------------------------------

  pw.Widget _totals(PurchaseBillEntity bill) {
    final rows = <PdfTotalRow>[];
    void row(String label, String value) => rows.add(PdfTotalRow(label, value));

    row('Subtotal', Formatters.money(dec(bill.subTotal)));
    final invoiceDiscount = GstEngine.resolvedInvoiceDiscount(
      subTotal: bill.subTotal,
      itemDiscount: bill.itemDiscount,
      invoiceDiscountPercent: bill.invoiceDiscountPercent,
      invoiceDiscountAmount: bill.invoiceDiscountAmount,
    );
    if (bill.itemDiscount.abs() > 0.001 || invoiceDiscount.abs() > 0.001) {
      row(
        'Discount',
        '- ${Formatters.money(dec(bill.itemDiscount + invoiceDiscount))}',
      );
    }
    if (bill.shippingCharge.abs() > 0.001) {
      row('Shipping / Freight', Formatters.money(dec(bill.shippingCharge)));
    }
    if (bill.otherCharges.abs() > 0.001) {
      row('Other Charges', Formatters.money(dec(bill.otherCharges)));
    }
    row('Taxable Value', Formatters.money(dec(bill.taxableValue)));
    if (bill.cgst.abs() > 0.001) {
      row('CGST', Formatters.money(dec(bill.cgst)));
    }
    if (bill.sgst.abs() > 0.001) {
      row(_secondTaxHead(bill), Formatters.money(dec(bill.sgst)));
    }
    if (bill.igst.abs() > 0.001) {
      row('IGST', Formatters.money(dec(bill.igst)));
    }
    if (bill.cess.abs() > 0.001) {
      row('Cess', Formatters.money(dec(bill.cess)));
    }
    // TDS comes off the top, not out of the tax: the rate is applied to the
    // taxable value (see GstEngine.settlementTax), and what the supplier is
    // actually paid is the grand total below it.
    if (bill.tds.abs() > 0.001) {
      row(
        bill.tdsRate > 0
            ? 'TDS @ ${Formatters.percent(bill.tdsRate)}'
            : 'TDS',
        '- ${Formatters.money(dec(bill.tds.abs()))}',
      );
    }
    if (bill.roundOff.abs() > 0.001) {
      row(
        'Round Off',
        '${bill.roundOff < 0 ? '-' : ''}'
            '${Formatters.money(dec(bill.roundOff.abs()))}',
      );
    }

    return totalsTable(
      rows,
      grandLabel: 'TOTAL PAYABLE',
      grandTotal: Formatters.money(dec(bill.grandTotal)),
      afterGrand: _settlement(bill),
    );
  }

  /// What the firm has already paid the supplier, under the payable total.
  ///
  /// The same two lines the sales invoice prints, and for the same reason: a
  /// bill sitting half-settled with no figure for what has gone out is the
  /// document the supplier's accountant reconciles against and cannot.
  List<PdfTotalRow> _settlement(PurchaseBillEntity bill) {
    final rows = <PdfTotalRow>[];
    if (bill.paidAmount.abs() > 0.001) {
      rows.add(PdfTotalRow('Amount Paid', Formatters.money(dec(bill.paidAmount))));
    }
    if (bill.balanceDue > 0.001) {
      rows.add(PdfTotalRow(
        'Balance Due',
        Formatters.money(dec(bill.balanceDue)),
        emphasize: true,
      ));
    }
    return rows;
  }

  /// The two facts about a purchase that change what the reader owes and
  /// whether the tax can be claimed — both printed, because both are checked
  /// during audit and neither is visible anywhere else on the document.
  List<pw.Widget> _complianceNotes(PurchaseBillEntity bill) {
    final notes = <pw.Widget>[];
    if (bill.reverseCharge) {
      notes.add(noteBlock(
        'Reverse Charge',
        'Tax on this purchase is payable by the supplier, not by the buyer.',
      )!);
    }
    if (bill.isInwardSupplyFromUnregistered) {
      notes.add(noteBlock(
        'Unregistered Supplier',
        'Inward supply from an unregistered person. No input tax credit is '
        'available on this bill.',
      )!);
    }
    return notes;
  }

  // ---- Voucher wording ---------------------------------------------------

  String _modeLabel(PaymentEntity payment) {
    final mode = payment.mode;
    return switch (mode) {
      'cash' => 'Cash',
      'upi' => 'UPI',
      'bank' => 'Bank transfer',
      'card' => 'Card',
      'cheque' => 'Cheque',
      _ => _titleCase(mode),
    };
  }

  String _referenceLabel(PaymentEntity payment) =>
      payment.mode == 'cheque' ? 'Cheque No.' : 'Reference';

  /// The cheque's state in the operator's words, with the bank's reason when
  /// there was one. A voucher that says only "bounced" is the document the
  /// supplier asks about.
  String _chequeStatus(PaymentEntity payment) {
    final raw = payment.chequeStatus ?? '';
    final status = switch (raw) {
      'pending' => 'In hand — not deposited',
      'deposited' => 'Deposited — awaiting clearance',
      'cleared' => 'Cleared',
      'bounced' => 'Returned unpaid',
      _ => _titleCase(raw),
    };
    final reason = (payment.bounceReason ?? '').trim();
    return reason.isEmpty ? status : '$status — $reason';
  }
}
