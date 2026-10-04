import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/utils/money.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import 'transaction_common.dart';

/// **Bill Wise Profit** — what each sale actually made.
///
/// The only report in this category that needs a **cost**, and the reason is
/// that every other one reports revenue. Revenue is on the invoice; profit is
/// not, and a shopkeeper deciding whether to keep selling an item cannot get it
/// from the sale register.
///
/// **Where the cost comes from.** `stock_movements.unit_cost` is stamped when
/// the goods left, at the weighted moving average of that moment (schema v11).
/// That is the right figure for the question being asked: *what did this sale
/// cost me*, not *what would it cost me today*. Re-valuing at today's average is
/// the mistake that makes last quarter's profit change when you buy something
/// this week.
///
/// **A credit note reverses the margin, it does not add to it.** The stock
/// movement that put the goods back is positive with a positive cost, so the
/// cost column reads negative and the profit comes out the mirror image of the
/// original sale. Printing a credit note as a fresh positive sale is plan rule 2,
/// and it is why the cost is derived from the movements rather than from a
/// "current item price" lookup.
///
/// **A zero cost is reported, not hidden.** An invoice whose items were never
/// costed shows 100% margin and says so in a note, because a margin column that
/// silently reads 100% is the most expensive kind of wrong number in this app.
const ReportSpec billWiseProfitSpec = ReportSpec(
  id: 'bill_wise_profit',
  title: 'Bill Wise Profit',
  category: 'Transaction',
  groupBy: ReportGroupBy.month,
  sort: ReportSort(columnKey: 'date'),
  columns: [
    ReportColumn(
      key: 'date',
      label: 'Date',
      kind: ReportValueKind.date,
      wideOnly: true,
    ),
    ReportColumn(key: 'number', label: 'Invoice No.', emphasise: true),
    ReportColumn(key: 'party', label: 'Party', flex: 3),
    ReportColumn(key: 'taxable', label: 'Sales', kind: ReportValueKind.money),
    ReportColumn(
      key: 'cogs',
      label: 'Cost of goods',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(
      key: 'profit',
      label: 'Gross profit',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
    ReportColumn(key: 'margin', label: 'Margin', kind: ReportValueKind.percent),
    ReportColumn(
      key: 'total',
      label: 'Invoice total',
      kind: ReportValueKind.money,
      flex: 2,
    ),
  ],
  footnote:
      'Cost of goods is the weighted moving average recorded when the '
      'goods left stock, not today\'s price. A margin of 100% means the item '
      'was never costed — check the stock report before relying on it.',
);

const ReportDefinition billWiseProfit = ReportDefinition(
  spec: billWiseProfitSpec,
  source: CallbackReportSource(
    sourceId: 'bill_wise_profit',
    query: billWiseProfitRows,
    notes: _billWiseNotes,
  ),
);

/// One row per sale, with its cost of goods sold.
Future<List<ReportRow>> billWiseProfitRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final documents =
      await (db.select(db.salesInvoices)
            ..where((t) => liveSalesIn(window, firmId, db.salesInvoices))
            ..orderBy([
              (t) => OrderingTerm.asc(t.invoiceDate),
              (t) => OrderingTerm.asc(t.number),
            ]))
          .get();
  if (documents.isEmpty) return const [];

  final costByInvoice = await _costOfGoodsByInvoice(
    db,
    firmId,
    window,
    documents.map((d) => d.id).toList(),
  );

  final rows = <ReportRow>[];
  for (final doc in documents) {
    final sales = _signed(dec(doc.taxableValue), doc.docType);
    final cost = costByInvoice[doc.id] ?? Decimal.zero;
    final profit = sales - cost;

    rows.add(
      ReportRow({
        'date': doc.invoiceDate,
        'number': doc.number,
        'party': doc.partyName ?? '—',
        'taxable': sales,
        'cogs': cost,
        'profit': profit,
        // Margin on **sales**, never on the invoice total. Dividing by the
        // total would fold output GST into the denominator and understate
        // every margin by the tax rate.
        'margin': sales == Decimal.zero
            ? Decimal.zero
            : Money.div(profit * Decimal.fromInt(100), sales),
        'total': _signed(dec(doc.grandTotal), doc.docType),
      }, label: doc.number),
    );
  }
  return rows;
}

/// A credit note prints as a negative of its own invoice, because it returns
/// what was originally sold. Rendering it as a fresh positive sale is plan rule
/// 2, and it is why the cost is taken from the stock movements rather than from
/// a "current item price" lookup.
Decimal _signed(Decimal value, String docType) =>
    signFor(docType) < 0 ? -value : value;

/// Σ cost of goods sold per invoice, aggregated in SQL.
///
/// `SUM(quantity * unit_cost)` is **negated** because a sale's movement carries
/// a negative quantity (stock left) against a positive cost. Aggregating here
/// rather than reading the movements into Dart is the point of the query: a
/// window with two thousand invoices would otherwise pull two thousand rows per
/// document through the Dart heap.
Future<Map<String, Decimal>> _costOfGoodsByInvoice(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  List<String> invoiceIds,
) async {
  final out = <String, Decimal>{};
  if (invoiceIds.isEmpty) return out;
  // The query builder rather than `customSelect`, so the `IN (…)` expansion and
  // its variable chunking are drift's problem rather than ours: a quarter with
  // two thousand invoices exceeds SQLite's 999-variable cap on a raw `IN`.
  final cost = (db.stockMovements.quantity * db.stockMovements.unitCost).sum();
  final query = db.selectOnly(db.stockMovements)
    ..addColumns([db.stockMovements.sourceId, cost])
    ..where(
      db.stockMovements.firmId.equals(firmId) &
          db.stockMovements.source.equals('sales_invoices') &
          db.stockMovements.kind.isIn(const ['sale', 'sale_return']) &
          ReportFilters.within(db.stockMovements.date, window) &
          db.stockMovements.sourceId.isIn(invoiceIds),
    )
    ..groupBy([db.stockMovements.sourceId]);
  for (final row in await query.get()) {
    final invoiceId = row.read(db.stockMovements.sourceId);
    if (invoiceId == null) continue;
    final total = dec(row.read(cost) ?? 0);
    // Negated: a sale's movement carries a negative quantity against a
    // positive cost, so the raw sum is already negative of what the column
    // should print. Doing it here rather than per row keeps the sign rule in
    // exactly one place.
    if (total != Decimal.zero) out[invoiceId] = -total;
  }
  return out;
}

/// Say so, loudly, when the margin column is measuring nothing.
List<String> _billWiseNotes(ReportResult result) {
  final uncosted = <String>[];
  for (final row in result.rows) {
    if (row.number(_cogsColumn) == Decimal.zero) {
      uncosted.add('${row.cells['number']}');
    }
  }
  if (uncosted.isEmpty) return const [];
  final shown = uncosted.take(5).join(', ');
  final more = uncosted.length > 5 ? ' and ${uncosted.length - 5} more' : '';
  return [
    'No cost of goods recorded for $shown$more — their margin is not a real '
        'figure. Cost the items (Stock report), then reopen this report.',
  ];
}

const ReportColumn _cogsColumn = ReportColumn(
  key: 'cogs',
  label: 'Cost of goods',
  kind: ReportValueKind.money,
);
