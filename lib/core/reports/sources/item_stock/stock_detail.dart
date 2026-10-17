import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import 'item_common.dart';

/// **Stock Detail** — every movement, in order, with the balance it left behind.
///
/// `layout: document` because the whole content is a **running balance**, and a
/// running balance in a plain grid is not readable: the reader has to carry the
/// previous row in their head, which is exactly the arithmetic the column is
/// there to do. Bespoke is also what lets each row name the document it came
/// from, which a stock report without cannot — "2 out" says nothing about
/// which sale.
///
/// **The opening balance is the item's balance at the window's start**, computed
/// by replaying every movement dated before it. Not the sum of the window's
/// rows, which would start every item from nothing, and not the current balance,
/// which would be the closing figure sitting above rows that have not happened
/// yet. All three are different numbers and only this one makes the column
/// add up.
///
/// **A row's own quantity carries the sign it was written with** — a sale is
/// negative, a return positive. The balance column then needs no arithmetic at
/// all: it is the previous balance plus this row, and a reader can check any row
/// by eye.
const ReportSpec stockDetailSpec = ReportSpec(
  id: 'stock_detail',
  title: 'Stock Detail',
  category: 'Item/Stock',
  layout: ReportLayout.document,
  sort: ReportSort(columnKey: 'date', descending: false),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kItemFilterId,
      label: 'Item',
      value: null,
      hint: 'Every item',
    ),
  ],
  columns: [
    ReportColumn(key: 'item', label: 'Item', flex: 3, emphasise: true),
    // Identity, not presentation. `wideOnly` keeps it out of the table and the
    // exports while the Stock Detail document reads it to group by item.
    ReportColumn(key: 'itemId', label: 'Item ID', wideOnly: true),
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(key: 'kind', label: 'Type'),
    ReportColumn(key: 'number', label: 'Document', flex: 2),
    ReportColumn(key: 'qty', label: 'Qty', kind: ReportValueKind.quantity),
    ReportColumn(key: 'rate', label: 'Rate', kind: ReportValueKind.rate),
    ReportColumn(key: 'value', label: 'Value', kind: ReportValueKind.money),
    ReportColumn(
      key: 'balance',
      label: 'Balance',
      // `running`, not `quantity`: a running balance is the account's position
      // after each movement, and summing a column of them is meaningless.
      // Declared as `quantity` it was summable, so `ReportRunner.fold` added
      // every row's balance into the grand total — opening 100, sale −30,
      // sale −20 printed a total of **220** where the closing balance is 50,
      // in the table and in the CSV, Excel and PDF alike. `party_statement` and
      // `cash_flow` already declare theirs `running`; this one missed.
      kind: ReportValueKind.running,
      emphasise: true,
    ),
  ],
  footnote:
      'The opening balance is what was on the shelf at the start of this period, '
      'replayed from the movement log. Qty is signed as it was recorded: a sale '
      'is negative, a return positive. Rate is the weighted moving average at '
      'the moment the goods moved.',
);

const ReportDefinition stockDetail = ReportDefinition(
  spec: stockDetailSpec,
  source: CallbackReportSource(
    sourceId: 'stock_detail',
    query: stockDetailRows,
    options: itemOptions,
  ),
);

Future<List<ReportRow>> stockDetailRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedItemId(filters);
  final items = await allLiveItems(db, firmId, selected: selected);
  if (items.isEmpty) return const [];

  final movements = db.stockMovements;
  final query = db.select(movements)
    ..where(
      (_) =>
          movements.firmId.equals(firmId) &
          itemScope(movements.itemId, selected),
    )
    // `id` last, for the same reason as everywhere else: two movements written
    // in the same millisecond have no other defined order, and the balance
    // depends on which came first.
    ..orderBy([
      (m) => OrderingTerm.asc(m.itemId),
      (m) => OrderingTerm.asc(m.date),
      (m) => OrderingTerm.asc(m.id),
    ]);

  // Balances are carried per item across the whole log, so the opening row of
  // each item shows what it held before the window rather than starting from
  // zero. The map is reset on an item change rather than keyed by id, because
  // the ordering above guarantees every row for an item is contiguous.
  var current = '';
  var balance = Decimal.zero;
  final rows = <ReportRow>[];
  for (final m in await query.get()) {
    if (m.itemId != current) {
      current = m.itemId;
      balance = Decimal.zero;
    }
    final inWindow = _within(m.date, window);
    // **Every** movement moves the balance, in or out of the window. Guarding
    // this on `inWindow` — which is the obvious thing to write, since the
    // out-of-window rows are about to be filtered away — is precisely wrong: the
    // opening balance *is* the sum of those rows, so skipping them reports the
    // first in-window row's balance as if the item had been empty since the
    // beginning of time. Ten bags bought in January, two sold in June, and the
    // June row would claim a balance of −2.
    balance += dec(m.quantity);
    final info = items[m.itemId];
    rows.add(
      ReportRow({
        'item': info?.name ?? '(deleted item)',
        // The **id**, carried so anything that groups this report can key on
        // identity rather than on the printed name. Two genuinely different items
        // can share a name — an IT bag and a cement bag, or a 25 kg and a 50 kg
        // variant both entered as "Cement 50" — and the Stock Detail document
        // builds one card per item so a reader can follow one balance down. Keyed
        // on the name, those two merge into a single card whose header shows
        // whichever item happened to sort last.
        'itemId': m.itemId,
        'date': m.date,
        'kind': movementKindLabel(m.kind),
        'number': m.sourceNumber ?? '',
        // The signed quantity exactly as stored. Negative red is meaningful
        // here — it is not a negative stock, it is goods leaving.
        'qty': inWindow ? dec(m.quantity) : '',
        'rate': dec(m.unitCost),
        'value': inWindow ? dec(m.quantity) * dec(m.unitCost) : '',
        'balance': inWindow ? balance : '',
      }, label: info?.name ?? m.itemId),
    );
  }

  // Rows outside the window were carried for their balance and carry no figures
  // of their own. The window is not a filter here: dropping them would make the
  // opening balance unreproducible, since it is the sum of exactly those rows.
  return rows.where((r) => r.cells['qty'] != '').toList();
}

/// Whether a date falls in the window, resolved in Dart.
///
/// The same rule as `ReportFilters.within`, called on an already-fetched row
/// because this query deliberately reads **the whole log** — the balance before
/// the window cannot be computed from the window's rows.
bool _within(DateTime date, ReportWindow window) {
  if (window.from != null && date.isBefore(window.from!)) return false;
  if (window.to != null && date.isAfter(window.to!)) return false;
  return true;
}

/// The movement kind in words the reader recognises.
///
/// An unrecognised kind is passed through as stored. A movement kind is a
/// free-text column and the writers set it; a future kind this app does not yet
/// have a word for should appear on the ledger rather than be printed as
/// nothing, because an unexplained row in a stock ledger is a real problem.
String movementKindLabel(String kind) => switch (kind) {
  'opening' => 'Opening',
  'purchase' => 'Purchase',
  'purchase_return' => 'Purchase return',
  'sale' => 'Sale',
  'sale_return' => 'Sale return',
  'adjustment' => 'Adjustment',
  'transfer_in' => 'Transfer in',
  'transfer_out' => 'Transfer out',
  final other => other,
};
