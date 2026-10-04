import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import 'transaction_common.dart';

/// **Purchase** — the purchase register for the window.
///
/// The mirror of [saleRegister], and deliberately not a copy of it: three of
/// its columns have no sales counterpart and each one is a real trap.
///
/// - **`supplierRef`** is the supplier's own invoice number, not our bill
///   number. A purchase is entered twice — once by us and once by them — and
///   the supplier's copy is the one a GST reconciliation matches on.
/// - **`tds`** is a *deduction*, so it is not part of what the bill costs us.
///   It is reported on its own column rather than netted into the total,
///   because netting it makes the total disagree with the printed bill and with
///   the bank, by exactly the TDS.
/// - **A debit note is negative**, and it returns goods, so it reverses
///   `taxableValue` rather than adding to it.
const ReportSpec purchaseRegisterSpec = ReportSpec(
  id: 'purchase',
  title: 'Purchase',
  category: 'Transaction',
  groupBy: ReportGroupBy.month,
  sort: ReportSort(columnKey: 'date'),
  columns: [
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(key: 'number', label: 'Bill No.', emphasise: true),
    ReportColumn(
      key: 'supplierRef',
      label: 'Supplier Inv.',
      flex: 2,
      wideOnly: true,
    ),
    ReportColumn(key: 'type', label: 'Type', flex: 2),
    ReportColumn(key: 'supplier', label: 'Supplier', flex: 3),
    ReportColumn(key: 'taxable', label: 'Taxable', kind: ReportValueKind.money),
    ReportColumn(
      key: 'discount',
      label: 'Discount',
      kind: ReportValueKind.money,
      wideOnly: true,
    ),
    ReportColumn(key: 'tax', label: 'Tax', kind: ReportValueKind.money),
    ReportColumn(
      key: 'tds',
      label: 'TDS',
      kind: ReportValueKind.money,
      colorize: true,
    ),
    ReportColumn(
      key: 'total',
      label: 'Total',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(
      key: 'balance',
      label: 'Payable',
      kind: ReportValueKind.money,
      colorize: true,
    ),
  ],
  footnote:
      'Taxable value excludes GST. TDS is shown separately — it is '
      'deducted at payment, so it is not part of what the bill cost.',
);

const ReportDefinition purchaseRegister = ReportDefinition(
  spec: purchaseRegisterSpec,
  source: CallbackReportSource(sourceId: 'purchase', query: purchaseRows),
);

/// The purchase register's rows.
Future<List<ReportRow>> purchaseRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final query = db.select(db.purchaseBills)
    ..where((t) => livePurchasesIn(window, firmId, db.purchaseBills))
    ..orderBy([
      (t) => OrderingTerm.asc(t.billDate),
      (t) => OrderingTerm.asc(t.number),
    ]);

  final documents = await query.get();
  return [
    for (final bill in documents)
      ReportRow({
        'date': bill.billDate,
        'number': bill.number,
        'supplierRef': bill.supplierInvoiceNumber ?? '—',
        'type': docTypeLabel(bill.docType),
        'supplier': bill.partyName ?? '—',
        'taxable': _signed(dec(bill.taxableValue), bill.docType),
        'discount': _signed(
          discountOf(
            itemDiscount: bill.itemDiscount,
            invoiceDiscount: bill.invoiceDiscountAmount,
          ),
          bill.docType,
        ),
        'tax': _signed(
          outputTaxOf(
            cgst: bill.cgst,
            sgst: bill.sgst,
            igst: bill.igst,
            cess: bill.cess,
          ),
          bill.docType,
        ),
        // A debit note reverses the TDS deducted, so it is signed the same
        // way as everything else on the document.
        'tds': _signed(dec(bill.tds), bill.docType),
        // The **face value** of the bill, not the stored `grandTotal`.
        // `PurchaseRepository.save` writes `grandTotal` already net of TDS,
        // because that is the amount payable to the supplier. Printing that
        // under a heading called "Total" makes the register disagree with the
        // supplier's own invoice by exactly the TDS — and TDS is the one
        // figure on this row the reader is checking the deduction against.
        // The payable is the `balance` column, which is derived from the same
        // stored total, so the two still agree with each other.
        'total': _signed(dec(bill.grandTotal) + dec(bill.tds), bill.docType),
        'balance': dec(bill.balanceDue),
      }, label: bill.number),
  ];
}

Decimal _signed(Decimal value, String docType) =>
    signFor(docType) < 0 ? -value : value;
