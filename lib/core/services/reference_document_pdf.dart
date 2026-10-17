import 'dart:io';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../constants/indian_states.dart';
import '../database/app_database.dart';
import '../domain/gst_registration.dart';
import '../engine/gst_engine.dart';
import '../utils/formatters.dart';
import '../utils/number_words.dart';
import 'pdf_fonts.dart';
import 'pdf_sections.dart';
import 'pdf_template_style.dart';
import 'upi_qr.dart';

/// Reference layouts consume saved figures, never recalculate document taxes.
class ReferenceDocument {
  ReferenceDocument({
    required this.title,
    required this.number,
    required this.date,
    required this.party,
    required this.lines,
    required this.taxable,
    required this.total,
    required this.cgst,
    required this.sgst,
    required this.igst,
    required this.cess,
    required this.paid,
    required this.balance,
    required this.interState,
    required this.showTax,
    this.due,
    this.shipping,
    this.placeOfSupply,
    this.notes,
    this.terms,
    this.discount = 0,
    this.shippingCharge = 0,
    this.otherCharges = 0,
    this.roundOff = 0,
    this.adjustment = 0,
    this.adjustmentLabel = '',
    this.collectable = false,
    this.purchase = false,
    this.cancelled = false,
  });
  factory ReferenceDocument.sale(
    FirmEntity firm,
    SalesInvoiceEntity invoice,
    List<SalesInvoiceItemEntity> items,
  ) {
    final showTax =
        firm.isGstRegistered ||
        invoice.cgst + invoice.sgst + invoice.igst + invoice.cess > 0;
    return ReferenceDocument(
      title: switch (invoice.docType) {
        'quotation' => 'QUOTATION',
        'sales_order' => 'SALES ORDER',
        'delivery_note' => 'DELIVERY NOTE',
        'credit_note' => 'CREDIT NOTE',
        _ => showTax ? 'TAX INVOICE' : 'INVOICE',
      },
      number: invoice.number,
      date: invoice.invoiceDate,
      due: invoice.dueDate,
      party: PdfParty(
        label: 'Customer Details:',
        name: invoice.partyName ?? 'Walk-in Customer',
        address: [
          invoice.billingAddress,
          if ((invoice.partyPhone ?? '').isNotEmpty)
            'Ph: ${invoice.partyPhone}',
        ].whereType<String>().join('\n'),
        gstin: invoice.partyGstin,
      ),
      shipping: invoice.shippingAddress ?? invoice.billingAddress,
      placeOfSupply: invoice.placeOfSupply,
      lines: items.map(PdfLineItem.fromSales).toList(),
      taxable: invoice.taxableValue,
      total: invoice.grandTotal,
      cgst: invoice.cgst,
      sgst: invoice.sgst,
      igst: invoice.igst,
      cess: invoice.cess,
      paid: invoice.paidAmount,
      balance: invoice.balanceDue,
      interState: invoice.isInterState,
      showTax: showTax,
      notes: invoice.notes ?? firm.invoiceNotes,
      terms: invoice.terms ?? firm.invoiceTerms,
      discount:
          invoice.itemDiscount +
          GstEngine.resolvedInvoiceDiscount(
            subTotal: invoice.subTotal,
            itemDiscount: invoice.itemDiscount,
            invoiceDiscountPercent: invoice.invoiceDiscountPercent,
            invoiceDiscountAmount: invoice.invoiceDiscountAmount,
          ),
      shippingCharge: invoice.shippingCharge,
      roundOff: invoice.roundOff,
      adjustment: invoice.tcs,
      adjustmentLabel: 'TCS',
      collectable: invoice.docType == 'invoice',
      cancelled: invoice.status == 'cancelled',
    );
  }
  factory ReferenceDocument.purchaseBill(
    FirmEntity firm,
    PurchaseBillEntity bill,
    List<PurchaseBillItemEntity> items,
  ) => ReferenceDocument(
    title: switch (bill.docType) {
      'purchase_order' => 'PURCHASE ORDER',
      'debit_note' => 'DEBIT NOTE',
      _ => 'PURCHASE BILL',
    },
    number: bill.number,
    date: bill.billDate,
    due: bill.dueDate,
    party: PdfParty(
      label: 'Supplier Details:',
      name: bill.partyName ?? 'Supplier',
      gstin: bill.partyGstin,
    ),
    shipping: [
      firm.addressLine1,
      firm.addressLine2,
      firm.city,
      firm.pincode,
    ].whereType<String>().where((s) => s.isNotEmpty).join(', '),
    placeOfSupply: bill.placeOfSupply,
    lines: items.map(PdfLineItem.fromPurchase).toList(),
    taxable: bill.taxableValue,
    total: bill.grandTotal,
    cgst: bill.cgst,
    sgst: bill.sgst,
    igst: bill.igst,
    cess: bill.cess,
    paid: bill.paidAmount,
    balance: bill.balanceDue,
    interState: bill.isInterState,
    showTax: bill.cgst + bill.sgst + bill.igst + bill.cess > 0,
    notes: [
      bill.notes,
      if ((bill.supplierInvoiceNumber ?? '').isNotEmpty)
        'Supplier invoice: ${bill.supplierInvoiceNumber}',
      if (bill.reverseCharge) 'Reverse charge applies.',
      if (bill.isInwardSupplyFromUnregistered)
        'Inward supply from an unregistered supplier. No input tax credit.',
      if (!bill.itcEligible)
        'Supplier GST is included in cost. No input tax credit.',
    ].whereType<String>().join('\n'),
    terms: null,
    discount:
        bill.itemDiscount +
        GstEngine.resolvedInvoiceDiscount(
          subTotal: bill.subTotal,
          itemDiscount: bill.itemDiscount,
          invoiceDiscountPercent: bill.invoiceDiscountPercent,
          invoiceDiscountAmount: bill.invoiceDiscountAmount,
        ),
    shippingCharge: bill.shippingCharge,
    otherCharges: bill.otherCharges,
    roundOff: bill.roundOff,
    adjustment: -bill.tds,
    adjustmentLabel: 'TDS withheld',
    purchase: true,
    collectable: bill.docType == 'bill',
    cancelled: bill.status == 'cancelled',
  );
  final String title, number;
  final DateTime date;
  final DateTime? due;
  final PdfParty party;
  final List<PdfLineItem> lines;
  final String? shipping, placeOfSupply, notes, terms;
  final num taxable,
      total,
      cgst,
      sgst,
      igst,
      cess,
      paid,
      balance,
      discount,
      shippingCharge,
      otherCharges,
      roundOff,
      adjustment;
  final String adjustmentLabel;
  final bool interState, showTax, collectable, purchase, cancelled;
}

class ReferenceDocumentPdf {
  ReferenceDocumentPdf(this.firm, this.style);
  final FirmEntity firm;
  final PdfTemplateStyle style;
  static const rule = pw.BorderSide(width: .65);
  bool get ledger => style.id == 'ledger';
  bool get clean => style.id == 'clean';
  bool get business => style.id == 'business';
  bool get boxed => !clean;
  String numberLabel(ReferenceDocument d) => d.purchase
      ? 'Bill'
      : d.title == 'QUOTATION'
      ? 'Quotation'
      : d.title == 'INVOICE' || d.title == 'TAX INVOICE'
      ? 'Invoice'
      : 'Document';
  String secondTaxName(ReferenceDocument d) =>
      IndianStates.utgstStates.contains(firm.stateCode) ? 'UTGST' : 'SGST';
  String money(num n, {bool symbol = false}) =>
      Formatters.money(Decimal.parse(n.toString()), showSymbol: symbol);
  String rate(num n) =>
      '${n.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '')}%';
  pw.Widget text(
    String s, {
    bool bold = false,
    double size = 8.2,
    pw.TextAlign? align,
    PdfColor? color,
  }) => pw.Text(
    s,
    textAlign: align,
    style: pw.TextStyle(
      fontSize: size,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      color: color,
    ),
  );
  pw.Widget cell(pw.Widget child, {double padding = 5}) =>
      pw.Padding(padding: pw.EdgeInsets.all(padding), child: child);
  pw.Widget block(List<pw.Widget> children) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: children,
  );
  pw.Widget box(pw.Widget child, {double? height}) => pw.Container(
    height: height,
    width: double.infinity,
    decoration: pw.BoxDecoration(border: pw.Border.all(width: .65)),
    child: child,
  );

  Future<Uint8List> build(ReferenceDocument data) async {
    pw.MemoryImage? logo;
    try {
      if (firm.logoPath != null && File(firm.logoPath!).existsSync()) {
        logo = pw.MemoryImage(await File(firm.logoPath!).readAsBytes());
      }
    } catch (_) {
      /* Missing optional branding cannot prevent printing. */
    }
    final doc = pw.Document(theme: await PdfFonts.theme());
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(24, 24, 24, 25),
        maxPages: 100,
        footer: (context) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 8),
          child: text(
            'Page ${context.pageNumber} / ${context.pagesCount}',
            size: 7.3,
          ),
        ),
        build: (_) => [
          if (clean || business) ...[
            _openHeader(data, logo),
            pw.SizedBox(height: business ? 22 : 18),
            if (clean) _openParties(data) else _businessParties(data),
            if (clean) pw.SizedBox(height: 18),
          ] else
            _boxedHeader(data, logo),
          _items(data),
          if (clean || business)
            _compactBottom(data)
          else ...[
            if (!ledger) _fullTotals(data),
            _words(data, bordered: true),
          ],
          if (!clean && data.showTax) _hsn(data),
          if (!clean && !business) ...[
            _settlement(data, bordered: true),
            _bankSignature(data),
          ],
          if (clean) ...[
            pw.SizedBox(height: 7),
            _words(data),
            pw.SizedBox(height: 20),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(flex: 3, child: _notes(data)),
                pw.Expanded(child: _signature()),
              ],
            ),
          ] else if (business)
            _notesSignature(data)
          else
            _boxedNotes(data),
        ],
      ),
    );
    return doc.save();
  }

  pw.Widget _identity(pw.MemoryImage? logo) => pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      if (logo != null) ...[
        pw.Image(logo, width: 65, height: 75, fit: pw.BoxFit.contain),
        pw.SizedBox(width: 8),
      ],
      pw.Expanded(
        child: block([
          text(firm.legalName ?? firm.name, bold: true, size: 11),
          if ((firm.gstin ?? '').isNotEmpty)
            text('GSTIN ${firm.gstin}', bold: true),
          if ((firm.addressLine1 ?? '').isNotEmpty) text(firm.addressLine1!),
          if ((firm.addressLine2 ?? '').isNotEmpty) text(firm.addressLine2!),
          text(
            [
              firm.city,
              IndianStates.byCode(firm.stateCode)?.name,
              firm.pincode,
            ].whereType<String>().where((s) => s.isNotEmpty).join(', '),
          ),
          if ((firm.phone ?? '').isNotEmpty) text('Mobile ${firm.phone}'),
          if ((firm.email ?? '').isNotEmpty) text('Email ${firm.email}'),
          if ((firm.website ?? '').isNotEmpty) text('Website ${firm.website}'),
        ]),
      ),
    ],
  );
  pw.Widget _party(
    ReferenceDocument d, {
    bool shipping = false,
    String? label,
  }) => cell(
    block([
      text(
        label ?? (shipping ? 'Shipping address:' : d.party.label),
        bold: true,
      ),
      if (!shipping) text(d.party.name, bold: true),
      if (!shipping && (d.party.gstin ?? '').isNotEmpty)
        text('GSTIN: ${d.party.gstin}'),
      if ((shipping ? d.shipping : d.party.address)?.isNotEmpty ?? false)
        text((shipping ? d.shipping : d.party.address)!),
    ]),
  );
  pw.Widget _meta(ReferenceDocument d) => pw.Table(
    border: pw.TableBorder.all(width: .65),
    children: [
      pw.TableRow(
        children: [
          cell(
            block([
              text('${numberLabel(d)} #:', bold: true),
              pw.SizedBox(height: 4),
              text(d.number, bold: true),
            ]),
          ),
          cell(
            block([
              text('Date:', bold: true),
              pw.SizedBox(height: 4),
              text(DateFormat('dd MMM yyyy').format(d.date)),
            ]),
          ),
        ],
      ),
      pw.TableRow(
        children: [
          cell(
            block([
              text('Place of Supply:', bold: true),
              pw.SizedBox(height: 4),
              text(
                d.placeOfSupply == null
                    ? '-'
                    : '${d.placeOfSupply}-${IndianStates.byCode(d.placeOfSupply)?.name ?? ''}',
                bold: true,
              ),
            ]),
          ),
          cell(
            block([
              text('Due Date:', bold: true),
              pw.SizedBox(height: 4),
              text(
                d.due == null ? '-' : DateFormat('dd MMM yyyy').format(d.due!),
              ),
            ]),
          ),
        ],
      ),
    ],
  );
  pw.Widget _title(ReferenceDocument d) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      pw.Expanded(
        child: text(
          d.title,
          bold: true,
          size: 10,
          align: pw.TextAlign.center,
          color: PdfColor.fromHex('#17334f'),
        ),
      ),
      if (!d.purchase && d.title != 'QUOTATION')
        text('ORIGINAL FOR RECIPIENT', size: 7.5),
    ],
  );
  pw.Widget _boxedHeader(ReferenceDocument d, pw.MemoryImage? logo) => block([
    box(cell(_title(d), padding: 4)),
    pw.Table(
      border: pw.TableBorder.all(width: .65),
      columnWidths: const {0: pw.FlexColumnWidth(1), 1: pw.FlexColumnWidth(1)},
      children: [
        pw.TableRow(children: [cell(_identity(logo)), _meta(d)]),
        pw.TableRow(
          children: [
            pw.Container(
              constraints: const pw.BoxConstraints(minHeight: 75),
              child: _party(d),
            ),
            _party(d, shipping: true),
          ],
        ),
      ],
    ),
  ]);
  pw.Widget _openHeader(ReferenceDocument d, pw.MemoryImage? logo) => pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(flex: 3, child: _identity(logo)),
      pw.SizedBox(width: 15),
      pw.Expanded(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            text(
              d.title,
              bold: true,
              size: 10,
              color: business ? PdfColor.fromHex('#387399') : null,
            ),
            if (!d.purchase && d.title != 'QUOTATION')
              text('ORIGINAL FOR RECIPIENT', size: 7),
            if (clean) ...[
              text('${numberLabel(d)} #: ${d.number}'),
              text('Date: ${DateFormat('dd MMM yyyy').format(d.date)}'),
              if (d.due != null)
                text('Due Date: ${DateFormat('dd MMM yyyy').format(d.due!)}'),
            ],
          ],
        ),
      ),
    ],
  );
  pw.Widget _openParties(ReferenceDocument d) => pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        child: block([
          text(d.purchase ? 'Business:' : 'Bill From:', bold: true),
          text(firm.name, bold: true),
          text(
            [
              firm.addressLine1,
              firm.addressLine2,
              firm.city,
              firm.pincode,
            ].whereType<String>().join(', '),
          ),
          pw.SizedBox(height: 5),
          text('Ship From:', bold: true),
          text(firm.addressLine1 ?? firm.name),
          if (d.placeOfSupply != null) ...[
            pw.SizedBox(height: 4),
            text(
              'Place of Supply: ${d.placeOfSupply}-${IndianStates.byCode(d.placeOfSupply)?.name ?? ''}',
            ),
          ],
        ]),
      ),
      pw.SizedBox(width: 24),
      pw.Expanded(
        child: block([
          _party(d, label: d.purchase ? 'Supplier:' : 'Bill To:'),
          _party(d, shipping: true, label: 'Ship to:'),
        ]),
      ),
    ],
  );
  pw.Widget _businessParties(ReferenceDocument d) => pw.Table(
    border: pw.TableBorder.all(width: .65),
    children: [
      pw.TableRow(
        children: [
          block([_party(d), _party(d, shipping: true)]),
          block([
            _meta(d),
            cell(
              block([
                text('Dispatch From:', bold: true),
                text(firm.name),
                text(
                  [
                    firm.addressLine1,
                    firm.city,
                    firm.pincode,
                  ].whereType<String>().join(', '),
                ),
              ]),
            ),
          ]),
        ],
      ),
    ],
  );

  pw.Widget _items(ReferenceDocument d) {
    final headings = ledger
        ? [
            '#',
            'Item',
            'HSN/SAC',
            if (d.showTax) 'Tax',
            'Qty',
            'Rate/Item',
            'Per',
            'Amount',
          ]
        : [
            '#',
            'Item',
            'HSN/SAC',
            'Rate/Item',
            'Qty',
            if (d.showTax) 'Taxable Value',
            if (d.showTax)
              (business ? (d.interState ? 'IGST' : 'GST') : 'Tax Amount'),
            'Amount',
          ];
    final widths = ledger
        ? [18.0, 210.0, 52.0, if (d.showTax) 30.0, 48.0, 65.0, 28.0, 72.0]
        : [
            18.0,
            180.0,
            52.0,
            65.0,
            38.0,
            if (d.showTax) 70.0,
            if (d.showTax) 72.0,
            72.0,
          ];
    List<String> values(PdfLineItem l, int i) => ledger
        ? [
            '${i + 1}',
            l.name,
            l.hsn ?? '-',
            if (d.showTax) rate(l.gstRate),
            '${Formatters.qty(Decimal.parse(l.quantity.toString()))} ${l.unit}',
            money(l.rate),
            l.unit,
            money(l.taxableValue),
          ]
        : [
            '${i + 1}',
            l.name,
            l.hsn ?? '-',
            money(l.rate),
            '${Formatters.qty(Decimal.parse(l.quantity.toString()))} ${l.unit}',
            if (d.showTax) money(l.taxableValue),
            if (d.showTax)
              '${money(l.cgst + l.sgst + l.igst + l.cess)} (${rate(l.gstRate)})',
            money(l.total),
          ];
    pw.Widget itemCell(
      String value,
      int column, {
      bool heading = false,
      double? height,
    }) => pw.Container(
      height: height,
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: heading
          ? const pw.BoxDecoration(border: pw.Border(bottom: rule))
          : null,
      child: text(
        value,
        bold: heading || column == 1,
        size: heading ? 7 : 8,
        align: column <= 1 ? pw.TextAlign.left : pw.TextAlign.right,
      ),
    );
    return pw.Table(
      columnWidths: {
        for (var i = 0; i < widths.length; i++)
          i: pw.FlexColumnWidth(widths[i]),
      },
      border: pw.TableBorder(
        top: rule,
        bottom: rule,
        left: rule,
        right: rule,
        verticalInside: rule,
        horizontalInside: rule,
      ),
      children: [
        pw.TableRow(
          repeat: true,
          children: [
            for (var i = 0; i < headings.length; i++)
              itemCell(headings[i], i, heading: true),
          ],
        ),
        for (var i = 0; i < d.lines.length; i++)
          pw.TableRow(
            children: [
              for (var j = 0; j < headings.length; j++)
                itemCell(values(d.lines[i], i)[j], j),
            ],
          ),
        if (!clean && d.lines.length <= 6)
          pw.TableRow(
            children: [
              for (var i = 0; i < headings.length; i++)
                itemCell(
                  '',
                  i,
                  height: business
                      ? 30
                      : ledger
                      ? (60 - (_taxRows(d).length - 2).clamp(0, 8) * 12)
                            .clamp(0, 60)
                            .toDouble()
                      : (150 - (_taxRows(d).length - 2).clamp(0, 8) * 32)
                            .clamp(10, 150)
                            .toDouble(),
                ),
            ],
          ),
        if (ledger) ...[
          for (final figure in _figures(d))
            pw.TableRow(
              children: [
                for (var i = 0; i < headings.length; i++)
                  itemCell(
                    i == 1
                        ? figure.$1
                        : i == headings.length - 1
                        ? money(figure.$2, symbol: true)
                        : '',
                    i,
                  ),
              ],
            ),
          pw.TableRow(
            children: [
              for (var i = 0; i < headings.length; i++)
                itemCell(
                  i == 1
                      ? 'Total'
                      : i == headings.length - 1
                      ? money(d.total, symbol: true)
                      : headings[i] == 'Qty'
                      ? Formatters.qty(
                          Decimal.parse(
                            d.lines
                                .fold<num>(0, (a, l) => a + l.quantity)
                                .toString(),
                          ),
                        )
                      : '',
                  i,
                  heading: true,
                ),
            ],
          ),
        ],
      ],
    );
  }

  List<(String, num)> _taxRows(ReferenceDocument d) {
    final rows = <(String, num)>[];
    // Group saved component amounts by rate; never derive tax from rounded totals.
    for (final component in ['CGST', d.interState ? 'IGST' : 'SGST']) {
      final amounts = <num, num>{};
      for (final l in d.lines) {
        final amount = component == 'CGST'
            ? l.cgst
            : component == 'IGST'
            ? l.igst
            : l.sgst;
        if (amount != 0) {
          final r = component == 'IGST' ? l.gstRate : l.gstRate / 2;
          amounts[r] = (amounts[r] ?? 0) + amount;
        }
      }
      final stored = component == 'CGST'
          ? d.cgst
          : component == 'IGST'
          ? d.igst
          : d.sgst;
      final label = component == 'SGST' ? secondTaxName(d) : component;
      if (amounts.isEmpty ||
          (amounts.values.fold<num>(0, (a, b) => a + b) - stored).abs() >
              .004) {
        if (stored != 0) rows.add((label, stored));
      } else {
        for (final r in amounts.keys.toList()..sort()) {
          rows.add(('$label ${rate(r)}', amounts[r]!));
        }
      }
    }
    if (d.cess != 0) rows.add(('Cess', d.cess));
    return rows;
  }

  List<(String, num)> _figures(ReferenceDocument d) => [
    if (d.discount != 0) ('Discount (included)', -d.discount),
    (d.showTax ? 'Taxable Amount' : 'Net Amount', d.taxable),
    if (d.shippingCharge != 0) ('Shipping / Freight', d.shippingCharge),
    if (d.otherCharges != 0) ('Other charges', d.otherCharges),
    ..._taxRows(d),
    if (d.adjustment != 0) (d.adjustmentLabel, d.adjustment),
    if (d.roundOff != 0) ('Round Off', d.roundOff),
  ];
  pw.Widget _totals(ReferenceDocument d, {bool settlement = true}) => block([
    for (final row in _figures(d))
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          children: [
            pw.Expanded(
              child: text(row.$1, bold: true, align: pw.TextAlign.right),
            ),
            pw.SizedBox(width: 12),
            text(money(row.$2, symbol: true), bold: true),
          ],
        ),
      ),
    box(
      cell(
        pw.Row(
          children: [
            pw.Expanded(
              child: text(
                'Total',
                bold: true,
                size: 11,
                align: pw.TextAlign.right,
              ),
            ),
            pw.SizedBox(width: 22),
            text(money(d.total, symbol: true), bold: true, size: 11),
          ],
        ),
        padding: 3,
      ),
    ),
    if (settlement) _settlement(d),
  ]);
  pw.Widget _fullTotals(ReferenceDocument d) => box(
    pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Expanded(
          child: cell(
            text(
              'Total Items / Qty: ${d.lines.length} / ${Formatters.qty(Decimal.parse(d.lines.fold<num>(0, (a, l) => a + l.quantity).toString()))}',
            ),
          ),
        ),
        pw.Expanded(child: cell(_totals(d, settlement: false), padding: 3)),
      ],
    ),
  );
  pw.Widget _words(ReferenceDocument d, {bool bordered = false}) {
    final widget = cell(
      text(
        'Amount Chargeable (in words): ${NumberToWords.indianCurrency(d.total.toDouble(), prefix: 'INR')}  E. & O.E.',
        size: 8,
      ),
    );
    return bordered ? box(widget) : widget;
  }

  pw.Widget _compactBottom(ReferenceDocument d) => pw.Container(
    decoration: boxed
        ? pw.BoxDecoration(border: pw.Border.all(width: .65))
        : null,
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          flex: 3,
          child: cell(
            block([
              if (business) ...[
                text(
                  'Total Items / Qty: ${d.lines.length} / ${Formatters.qty(Decimal.parse(d.lines.fold<num>(0, (a, l) => a + l.quantity).toString()))}',
                ),
                _words(d),
              ],
              _bank(d),
            ]),
          ),
        ),
        pw.Expanded(flex: 2, child: cell(_totals(d))),
      ],
    ),
  );
  pw.Widget _settlement(ReferenceDocument d, {bool bordered = false}) {
    if (!d.collectable) return pw.SizedBox();
    final widget = cell(
      block([
        if (d.cancelled)
          text('CANCELLED', bold: true, align: pw.TextAlign.right)
        else if (d.paid > .001 && d.balance <= .001)
          text('Amount Paid', bold: true, color: PdfColors.green700)
        else ...[
          if (d.paid > .001)
            text(
              'Amount Paid: ${money(d.paid, symbol: true)}',
              align: pw.TextAlign.right,
            ),
          text(
            'Balance Due: ${money(d.balance, symbol: true)}',
            bold: true,
            align: pw.TextAlign.right,
          ),
        ],
      ]),
      padding: 3,
    );
    return bordered
        ? box(pw.Align(alignment: pw.Alignment.centerRight, child: widget))
        : widget;
  }

  pw.Widget _bank(ReferenceDocument d) => pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        child: block([
          if (!d.purchase &&
              d.collectable &&
              !d.cancelled &&
              d.balance > .001 &&
              firm.showBankOnInvoice &&
              (firm.bankAccountNumber ?? '').isNotEmpty) ...[
            text('Bank Details:', bold: true),
            pw.SizedBox(height: 4),
            for (final row in [
              ('Bank:', firm.bankName),
              ('Account #:', firm.bankAccountNumber),
              ('IFSC:', firm.bankIfsc),
              ('Branch:', firm.bankBranch),
            ])
              if ((row.$2 ?? '').isNotEmpty)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 3),
                  child: text('${row.$1}  ${row.$2}'),
                ),
          ],
        ]),
      ),
      if (!d.purchase &&
          d.collectable &&
          !d.cancelled &&
          d.balance > .001 &&
          firm.showQrOnInvoice &&
          (firm.upiId ?? '').isNotEmpty)
        block([
          text('Pay using UPI:', bold: true),
          pw.SizedBox(height: 4),
          UpiQr.widget(
                UpiQr.upiUri(
                  payeeVpa: firm.upiId!,
                  payeeName: firm.name,
                  amount: d.balance.toStringAsFixed(2),
                  note: 'Invoice ${d.number}',
                  invoiceNumber: d.number,
                ),
                size: 72,
              ) ??
              pw.SizedBox(),
        ]),
    ],
  );
  pw.Widget _signature() => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.end,
    children: [
      text('For ${firm.name}', size: 8),
      pw.SizedBox(height: 55),
      if ((firm.signatureName ?? '').isNotEmpty)
        text(firm.signatureName!, bold: true, size: 10),
      pw.SizedBox(height: 10),
      text('Authorized Signatory', size: 7.5),
    ],
  );
  pw.Widget _bankSignature(ReferenceDocument d) => pw.Table(
    border: pw.TableBorder.all(width: .65),
    columnWidths: const {0: pw.FlexColumnWidth(2), 1: pw.FlexColumnWidth(1)},
    children: [
      pw.TableRow(
        children: [
          pw.Container(
            constraints: const pw.BoxConstraints(minHeight: 110),
            child: cell(_bank(d)),
          ),
          cell(_signature()),
        ],
      ),
    ],
  );
  pw.Widget _notes(ReferenceDocument d) => block([
    if ((d.notes ?? '').trim().isNotEmpty) ...[
      text('Notes:', bold: true),
      pw.SizedBox(height: 4),
      text(d.notes!),
      pw.SizedBox(height: 10),
    ],
    if ((d.terms ?? '').trim().isNotEmpty) ...[
      text('Terms and Conditions:', bold: true),
      pw.SizedBox(height: 4),
      text(d.terms!),
    ],
  ]);
  pw.Widget _notesSignature(ReferenceDocument d) => pw.Table(
    border: pw.TableBorder.all(width: .65),
    columnWidths: const {0: pw.FlexColumnWidth(3), 1: pw.FlexColumnWidth(1)},
    children: [
      pw.TableRow(children: [cell(_notes(d)), cell(_signature())]),
    ],
  );
  pw.Widget _boxedNotes(ReferenceDocument d) => pw.Table(
    columnWidths: const {0: pw.FlexColumnWidth(1), 1: pw.FlexColumnWidth(1)},
    border: pw.TableBorder.all(width: .65),
    children: [
      pw.TableRow(
        children: [
          pw.Container(
            constraints: const pw.BoxConstraints(minHeight: 70),
            child: cell(
              block([
                text('Notes:', bold: true),
                pw.SizedBox(height: 4),
                text(d.notes ?? ''),
              ]),
            ),
          ),
          cell(
            block([
              text('Terms and Conditions:', bold: true),
              pw.SizedBox(height: 4),
              text(d.terms ?? ''),
            ]),
          ),
        ],
      ),
    ],
  );
  pw.Widget _hsn(ReferenceDocument d) {
    final groups = <String, List<PdfLineItem>>{};
    for (final l in d.lines) {
      groups.putIfAbsent('${l.hsn ?? '-'}|${l.gstRate}', () => []).add(l);
    }
    final hasCess = d.lines.any((l) => l.cess != 0);
    num sum(List<PdfLineItem> lines, num Function(PdfLineItem) get) =>
        lines.fold<num>(0, (a, l) => a + get(l));
    pw.Widget value(String label, {bool bold = false}) => pw.Padding(
      padding: const pw.EdgeInsets.all(3),
      child: text(label, bold: bold, size: 7.5, align: pw.TextAlign.right),
    );
    pw.Widget pair(String left, String right, {bool bold = false}) => pw.Table(
      border: const pw.TableBorder(verticalInside: rule),
      children: [
        pw.TableRow(
          children: [
            value(left, bold: bold),
            value(right, bold: bold),
          ],
        ),
      ],
    );
    pw.Widget groupHead(String label) => block([
      pw.Center(child: cell(text(label, bold: true, size: 7.5), padding: 3)),
      pw.Container(
        decoration: const pw.BoxDecoration(border: pw.Border(top: rule)),
        child: pair('Rate', 'Amount', bold: true),
      ),
    ]);
    List<pw.Widget> values(List<PdfLineItem> lines, {bool total = false}) => [
      value(total ? 'TOTAL' : lines.first.hsn ?? '-', bold: total),
      value(money(sum(lines, (l) => l.taxableValue)), bold: total),
      pair(
        total
            ? ''
            : rate(
                d.interState ? lines.first.gstRate : lines.first.gstRate / 2,
              ),
        money(sum(lines, (l) => d.interState ? l.igst : l.cgst)),
        bold: total,
      ),
      if (!d.interState)
        pair(
          total ? '' : rate(lines.first.gstRate / 2),
          money(sum(lines, (l) => l.sgst)),
          bold: total,
        ),
      if (hasCess) value(money(sum(lines, (l) => l.cess)), bold: total),
      value(
        money(sum(lines, (l) => l.cgst + l.sgst + l.igst + l.cess)),
        bold: total,
      ),
    ];
    return pw.Table(
      border: pw.TableBorder.all(width: .5),
      columnWidths: {
        0: const pw.FlexColumnWidth(1.4),
        1: const pw.FlexColumnWidth(1.1),
        2: const pw.FlexColumnWidth(1.8),
        if (!d.interState) 3: const pw.FlexColumnWidth(1.8),
      },
      children: [
        pw.TableRow(
          repeat: true,
          children: [
            value('HSN/SAC', bold: true),
            value('Taxable Value', bold: true),
            groupHead(d.interState ? 'Integrated Tax' : 'Central Tax'),
            if (!d.interState)
              groupHead(secondTaxName(d) == 'UTGST' ? 'UT Tax' : 'State Tax'),
            if (hasCess) value('Cess', bold: true),
            value('Total Tax Amount', bold: true),
          ],
        ),
        for (final lines in groups.values) pw.TableRow(children: values(lines)),
        if (d.lines.isNotEmpty)
          pw.TableRow(children: values(d.lines, total: true)),
      ],
    );
  }
}
