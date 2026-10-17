import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/database/app_database.dart';
import '../../core/services/invoice_pdf.dart';
import '../../core/services/purchase_pdf.dart';
import '../../core/services/pdf_template_style.dart';
import 'atria_pdf_preview.dart';

class MobileTemplatePicker extends StatefulWidget {
  const MobileTemplatePicker({
    super.key,
    required this.firm,
    required this.selected,
    required this.onChanged,
    this.document = 0,
  });
  final int document;
  final FirmEntity firm;
  final PdfTemplateStyle selected;
  final ValueChanged<PdfTemplateStyle> onChanged;
  @override
  State<MobileTemplatePicker> createState() => _MobileTemplatePickerState();
}

class _MobileTemplatePickerState extends State<MobileTemplatePicker> {
  late final PageController _pages = PageController(
    initialPage: PdfTemplateStyle.all.indexOf(widget.selected).clamp(0, 4),
    viewportFraction: .88,
  );
  int get _document => widget.document;
  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pages,
            itemCount: PdfTemplateStyle.all.length,
            onPageChanged: (index) =>
                widget.onChanged(PdfTemplateStyle.all[index]),
            itemBuilder: (_, index) {
              final style = PdfTemplateStyle.all[index];
              return Container(
                margin: const EdgeInsets.fromLTRB(6, 12, 6, 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: style.id == widget.selected.id
                        ? scheme.primary
                        : Colors.transparent,
                  ),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Text(
                        style.name.toUpperCase(),
                        style: const TextStyle(
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (_, constraints) => AtriaPdfPreview(
                          key: ValueKey('${style.id}-$_document'),
                          height: constraints.maxHeight,
                          builder: (_) => _preview(style),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final style in PdfTemplateStyle.all)
              Container(
                margin: const EdgeInsets.all(4),
                width: style.id == widget.selected.id ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: style.id == widget.selected.id
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            widget.selected.description,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Future<Uint8List> _preview(PdfTemplateStyle style) async {
    final now = DateTime.now();
    final taxed = (widget.firm.gstin ?? '').trim().isNotEmpty;
    final docType = _document == 2 ? 'quotation' : 'invoice';
    final invoice = SalesInvoiceEntity(
      id: 'preview',
      firmId: widget.firm.id,
      docType: docType,
      number: _document == 2
          ? 'QUO-001'
          : _document == 1
          ? 'PUR-001'
          : 'INV-001',
      invoiceDate: now,
      dueDate: now.add(const Duration(days: 15)),
      status: 'confirmed',
      paymentStatus: 'unpaid',
      paidAmount: 0,
      balanceDue: taxed ? 1180 : 1000,
      partyName: _document == 1 ? 'Sample Supplier' : 'Sample Customer',
      billingAddress: 'Business address, India',
      isInterState: false,
      reverseCharge: false,
      isExport: false,
      subTotal: 1000,
      itemDiscount: 0,
      invoiceDiscountPercent: 0,
      invoiceDiscountAmount: 0,
      shippingCharge: 0,
      taxableValue: 1000,
      cgst: taxed ? 90 : 0,
      sgst: taxed ? 90 : 0,
      igst: 0,
      cess: 0,
      tcs: 0,
      tcsRate: 0,
      roundOff: 0,
      grandTotal: taxed ? 1180 : 1000,
      createdAt: now,
      updatedAt: now,
      isDeleted: false,
      sequence: 1,
    );
    final item = SalesInvoiceItemEntity(
      id: 'preview-line',
      invoiceId: 'preview',
      name: 'Sample Product',
      hsn: '8471',
      quantity: 2,
      unit: 'pcs',
      rate: 500,
      discountPercent: 0,
      discountAmount: 0,
      taxableValue: 1000,
      gstRate: taxed ? 18 : 0,
      cgst: taxed ? 90 : 0,
      sgst: taxed ? 90 : 0,
      igst: 0,
      cessRate: 0,
      cessAmount: 0,
      total: taxed ? 1180 : 1000,
      taxMode: 'exclusive',
      sortOrder: 0,
      isDeleted: false,
    );
    final firm = widget.firm.copyWith(pdfTemplate: style.id);
    if (_document == 1) {
      final bill = PurchaseBillEntity(
        id: 'preview',
        firmId: firm.id,
        docType: 'bill',
        itcEligible: true,
        number: 'PUR-001',
        billDate: now,
        status: 'confirmed',
        paymentStatus: 'unpaid',
        paidAmount: 0,
        balanceDue: 1180,
        partyName: 'Sample Supplier',
        isInterState: false,
        reverseCharge: false,
        isInwardSupplyFromUnregistered: false,
        subTotal: 1000,
        itemDiscount: 0,
        invoiceDiscountPercent: 0,
        invoiceDiscountAmount: 0,
        shippingCharge: 0,
        otherCharges: 0,
        taxableValue: 1000,
        cgst: 90,
        sgst: 90,
        igst: 0,
        cess: 0,
        tds: 0,
        tdsRate: 0,
        tdsSectionRate: 0,
        roundOff: 0,
        grandTotal: 1180,
        createdAt: now,
        updatedAt: now,
        isDeleted: false,
        sequence: 1,
      );
      final line = PurchaseBillItemEntity(
        id: 'preview-line',
        billId: 'preview',
        name: 'Sample Product',
        quantity: 2,
        unit: 'pcs',
        rate: 500,
        discountPercent: 0,
        discountAmount: 0,
        gstRate: 18,
        cessRate: 0,
        taxMode: 'exclusive',
        taxableValue: 1000,
        cgst: 90,
        sgst: 90,
        igst: 0,
        cessAmount: 0,
        total: 1180,
        sortOrder: 0,
        isDeleted: false,
      );
      return PurchasePdf.forFirm(firm).build(bill: bill, items: [line]);
    }
    return InvoicePdf.forFirm(firm).build(invoice: invoice, items: [item]);
  }
}
