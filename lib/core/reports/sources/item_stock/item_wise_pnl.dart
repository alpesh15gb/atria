import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import 'item_common.dart';

/// **Item Wise P&L** — what each product earned, what it cost, and the margin.
///
/// Revenue comes from the **sales lines** and cost from the **movement log**,
/// and they are not the same question. A sale is what the firm earned; an item
/// bought and never sold is still an asset, and counting its purchase as the
/// cost of the goods sold would turn a healthy stock position into a loss on
/// paper.
///
/// So cost is the goods that **left**, valued at the average they left at —
/// not the goods that arrived. The two coincide over a long window and diverge
/// sharply over a short one, which is exactly when somebody reads this report.
///
/// **A credit note reverses revenue *and* cost.** Returned goods were never
/// sold at a margin, so netting only the revenue reports the return's sale price
/// as pure profit — the one number on this screen that can read as a 100%
/// margin for a customer who gave something back.
///
/// **Services are included.** They are billed, they earn, and a consultancy's
/// best-selling "product" is usually its hours. They simply have no cost, which
/// the margin column shows honestly rather than by hiding the row.
const ReportSpec itemWisePnlSpec = ReportSpec(
  id: 'item_wise_pnl',
  title: 'Item Wise P&L',
  category: 'Item/Stock',
  sort: ReportSort(columnKey: 'profit', descending: true),
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
    ReportColumn(key: 'category', label: 'Category'),
    ReportColumn(key: 'saleQty', label: 'Sold', kind: ReportValueKind.quantity),
    ReportColumn(key: 'sale', label: 'Sale value', kind: ReportValueKind.money),
    ReportColumn(key: 'cost', label: 'Cost', kind: ReportValueKind.money),
    ReportColumn(
      key: 'profit',
      label: 'Profit',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
    ReportColumn(
      key: 'margin',
      label: 'Margin %',
      kind: ReportValueKind.percent,
      emphasise: true,
      colorize: true,
    ),
  ],
  footnote:
      'Sale value is taxable value, before GST — output tax is not revenue. '
      'Cost is what the goods that left cost, at the weighted moving average; '
      'stock still on the shelf is not counted as a cost. Credit notes are '
      'netted out of both sale value and cost.',
);

const ReportDefinition itemWisePnl = ReportDefinition(
  spec: itemWisePnlSpec,
  source: CallbackReportSource(
    sourceId: 'item_wise_pnl',
    query: itemWisePnlRows,
    options: itemOptions,
    notes: _itemWisePnlNotes,
  ),
);

Future<List<ReportRow>> itemWisePnlRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedItemId(filters);
  // Sales revenue for **every** item the firm sells — including services, which
  // have no stock and therefore no movement, and which are excluded from
  // `movementsByItem` only because that map is about the shelf.
  final trading = await tradingByItem(db, firmId, window, selected: selected);
  final movements = await movementsByItem(
    db,
    firmId,
    window,
    selected: selected,
  );
  final items = await itemsById(db, firmId, trading.keys.toList());
  final categories = await itemCategoryNames(db, firmId, items);

  final rows = <ReportRow>[];
  for (final entry in trading.entries) {
    final t = entry.value;
    if (t.isEmpty) continue;
    final info = items[entry.key];
    final name = info == null ? '(deleted item)' : info.name;

    // **Cost of goods sold, not cost of goods bought.** The outbound value in
    // the movement log is the average at which stock left — the same figure the
    // sale itself was costed at — so margin here ties to the ledger. Purchases
    // are deliberately not used: they are a change in the asset, not an expense.
    final cost = movements[entry.key]?.outboundValue ?? Decimal.zero;
    final profit = t.saleValue - cost;

    rows.add(
      ReportRow({
        'item': name,
        'category': categories[entry.key] ?? 'Ungrouped',
        'saleQty': t.saleQty,
        'sale': t.saleValue,
        'cost': cost,
        'profit': profit,
        'margin': marginPercent(profit, t.saleValue),
      }, label: name),
    );
  }
  return rows;
}

/// The margin here is `sale − cost of goods sold`, so an item bought and not
/// sold shows a margin of zero rather than a loss: nothing was earned and
/// nothing was costed against a sale. The stock is still an asset, and this
/// report is about what the period earned.
List<String> _itemWisePnlNotes(ReportResult result) =>
    itemProfitNotes(result.rows.toList());
