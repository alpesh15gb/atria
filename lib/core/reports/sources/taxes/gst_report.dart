import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../transaction/transaction_common.dart';

/// **GST Report** — invoice-level register of output GST (sales & credit notes)
/// and input GST (purchases & debit notes) within the selected period.
///
/// Gives the reader a unified line-by-line audit trail of every GST-bearing
/// document before aggregated return tables (GSTR-1 / GSTR-3B).
const ReportSpec gstReportSpec = ReportSpec(
  id: 'gst_report',
  title: 'GST Report',
  category: 'Taxes',
  groupBy: ReportGroupBy.category,
  sort: ReportSort(columnKey: 'date', descending: true),
  columns: [
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(
      key: 'invoice_no',
      label: 'Invoice No.',
      flex: 2,
      emphasise: true,
    ),
    ReportColumn(key: 'party', label: 'Party', flex: 3),
    ReportColumn(key: 'gstin', label: 'GSTIN', flex: 2, wideOnly: true),
    ReportColumn(key: 'voucher_type', label: 'Type', flex: 2, wideOnly: true),
    ReportColumn(
      key: 'taxable',
      label: 'Taxable',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(key: 'cgst', label: 'CGST', kind: ReportValueKind.money),
    ReportColumn(key: 'sgst', label: 'SGST', kind: ReportValueKind.money),
    ReportColumn(key: 'igst', label: 'IGST', kind: ReportValueKind.money),
    ReportColumn(
      key: 'cess',
      label: 'Cess',
      kind: ReportValueKind.money,
      wideOnly: true,
    ),
    ReportColumn(
      key: 'total_tax',
      label: 'Total Tax',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
  ],
  footnote:
      'Output GST on Sales is positive; Input GST on Purchases and Credit Notes '
      'is signed negative so the grand total reflects net GST liability.',
);

const ReportDefinition gstReport = ReportDefinition(
  spec: gstReportSpec,
  source: CallbackReportSource(
    sourceId: 'gst_report',
    query: gstReportRows,
    notes: _gstReportNotes,
  ),
);

Future<List<ReportRow>> gstReportRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final sales = db.salesInvoices;
  final purchases = db.purchaseBills;
  final parties = db.parties;

  final saleJoin =
      db.select(sales).join([
        leftOuterJoin(parties, parties.id.equalsExp(sales.partyId)),
      ])..where(
        sales.firmId.equals(firmId) &
            sales.docType.isIn(const ['invoice', 'credit_note']) &
            ReportFilters.isLive(
              status: sales.status,
              isDeleted: sales.isDeleted,
            ) &
            ReportFilters.within(sales.invoiceDate, window),
      );

  final purchaseJoin =
      db.select(purchases).join([
        leftOuterJoin(parties, parties.id.equalsExp(purchases.partyId)),
      ])..where(
        purchases.firmId.equals(firmId) &
            purchases.docType.isIn(const ['bill', 'debit_note']) &
            ReportFilters.isLive(
              status: purchases.status,
              isDeleted: purchases.isDeleted,
            ) &
            ReportFilters.within(purchases.billDate, window),
      );

  final saleRows = await saleJoin.get();
  final purchaseRows = await purchaseJoin.get();

  final rows = <ReportRow>[];

  for (final row in saleRows) {
    final inv = row.readTable(sales);
    final party = row.readTableOrNull(parties);
    final isCreditNote = inv.docType == 'credit_note';
    final sign = isCreditNote ? Decimal.fromInt(-1) : Decimal.one;

    final taxable = dec(inv.subTotal) * sign;
    final cgst = dec(inv.cgst) * sign;
    final sgst = dec(inv.sgst) * sign;
    final igst = dec(inv.igst) * sign;
    final cess = dec(inv.cess) * sign;
    final totalTax = cgst + sgst + igst + cess;

    rows.add(
      ReportRow({
        'date': inv.invoiceDate,
        'invoice_no': inv.number,
        'party': party?.name ?? 'Walk-in Customer',
        'gstin': party?.gstin ?? '',
        'voucher_type': isCreditNote
            ? 'Credit Note (Sales Return)'
            : 'Sales (Output GST)',
        'taxable': taxable,
        'cgst': cgst,
        'sgst': sgst,
        'igst': igst,
        'cess': cess,
        'total_tax': totalTax,
      }, label: inv.number),
    );
  }

  for (final row in purchaseRows) {
    final pur = row.readTable(purchases);
    final party = row.readTableOrNull(parties);
    final isDebitNote = pur.docType == 'debit_note';
    // Purchase input tax reduces net GST payable (negative), Debit note reverses it (positive)
    final sign = isDebitNote ? Decimal.one : Decimal.fromInt(-1);

    final taxable = dec(pur.subTotal) * sign;
    final cgst = dec(pur.cgst) * sign;
    final sgst = dec(pur.sgst) * sign;
    final igst = dec(pur.igst) * sign;
    final cess = dec(pur.cess) * sign;
    final totalTax = cgst + sgst + igst + cess;

    rows.add(
      ReportRow({
        'date': pur.billDate,
        'invoice_no': pur.number,
        'party': party?.name ?? 'Vendor',
        'gstin': party?.gstin ?? '',
        'voucher_type': isDebitNote
            ? 'Debit Note (Purchase Return)'
            : 'Purchase (Input ITC)',
        'taxable': taxable,
        'cgst': cgst,
        'sgst': sgst,
        'igst': igst,
        'cess': cess,
        'total_tax': totalTax,
      }, label: pur.number),
    );
  }

  return rows;
}

List<String> _gstReportNotes(ReportResult result) {
  if (result.isEmpty) return const [];
  final netTax = result.grandTotals['total_tax'] ?? Decimal.zero;
  if (netTax > Decimal.zero) {
    return ['Net GST Payable for the period: ₹${netTax.toStringAsFixed(2)}.'];
  } else if (netTax < Decimal.zero) {
    return [
      'Net Input Tax Credit (ITC) surplus for the period: ₹${(-netTax).toStringAsFixed(2)}.',
    ];
  }
  return const [];
}
