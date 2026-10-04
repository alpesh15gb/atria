import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import 'transaction_common.dart';

/// **Sale** — the sales register for the window.
///
/// Not a summary: one row per document, because the question a shopkeeper opens
/// this to answer is "what did I bill X in April", and a summary by party cannot
/// answer it. That is the same reason this report and *Sale Purchase By Party*
/// are both in the menu — one is the document list, the other is the analysis.
///
/// **The three figures it prints, and the one it must not.**
/// `taxable` is `taxable_value`, never `grand_total`: reporting the grand total
/// puts output tax into revenue, and the P&L then disagrees with the sales
/// register by exactly the GST charged. `discount` is the line discount *plus*
/// the header discount, because they are two different columns for two different
/// facts. `balance` is what is still owed, so a credit-limit decision can be
/// made from the same screen.
///
/// `paid` and `balance` are stored columns and are *not* signed by
/// [ReportColumn.negate]: on a credit note the repository already stores them
/// the way the document means them, and flipping them here would show a return
/// as though money were still owed for goods that came back.
const ReportSpec saleRegisterSpec = ReportSpec(
  id: 'sale',
  title: 'Sale',
  category: 'Transaction',
  groupBy: ReportGroupBy.month,
  sort: ReportSort(columnKey: 'date'),
  columns: [
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(key: 'number', label: 'Invoice No.', emphasise: true),
    ReportColumn(key: 'type', label: 'Type', flex: 2),
    ReportColumn(key: 'party', label: 'Party', flex: 3),
    ReportColumn(key: 'taxable', label: 'Taxable', kind: ReportValueKind.money),
    ReportColumn(
      key: 'discount',
      label: 'Discount',
      kind: ReportValueKind.money,
      wideOnly: true,
    ),
    ReportColumn(key: 'tax', label: 'Tax', kind: ReportValueKind.money),
    ReportColumn(
      key: 'total',
      label: 'Total',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(
      key: 'paid',
      label: 'Received',
      kind: ReportValueKind.money,
      colorize: true,
    ),
    ReportColumn(
      key: 'balance',
      label: 'Balance',
      kind: ReportValueKind.money,
      colorize: true,
    ),
  ],
  footnote:
      'Taxable value excludes GST. A credit note is shown as a negative, '
      'because it returns both the goods and the tax charged on them.',
);

const ReportDefinition saleRegister = ReportDefinition(
  spec: saleRegisterSpec,
  source: CallbackReportSource(sourceId: 'sale', query: saleRows),
);

/// The sale register's rows.
Future<List<ReportRow>> saleRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final query = db.select(db.salesInvoices)
    ..where((t) => liveSalesIn(window, firmId, db.salesInvoices))
    ..orderBy([
      (t) => OrderingTerm.asc(t.invoiceDate),
      (t) => OrderingTerm.asc(t.number),
    ]);

  final documents = await query.get();
  return [
    for (final doc in documents)
      ReportRow({
        'date': doc.invoiceDate,
        'number': doc.number,
        'type': docTypeLabel(doc.docType),
        'party': doc.partyName ?? '—',
        'taxable': _signed(dec(doc.taxableValue), doc.docType),
        'discount': _signed(
          discountOf(
            itemDiscount: doc.itemDiscount,
            invoiceDiscount: doc.invoiceDiscountAmount,
          ),
          doc.docType,
        ),
        'tax': _signed(
          outputTaxOf(
            cgst: doc.cgst,
            sgst: doc.sgst,
            igst: doc.igst,
            cess: doc.cess,
          ),
          doc.docType,
        ),
        'total': _signed(dec(doc.grandTotal), doc.docType),
        'paid': dec(doc.paidAmount),
        'balance': dec(doc.balanceDue),
      }, label: doc.number),
  ];
}

/// Apply the document's sign. A credit note returns what was sold, so every
/// figure on it — except the settlement columns — reads negative.
Decimal _signed(Decimal value, String docType) =>
    signFor(docType) < 0 ? -value : value;
