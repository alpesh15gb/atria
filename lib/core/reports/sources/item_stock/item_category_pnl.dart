import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import 'item_common.dart';

/// **Item Category Wise P&L** — the same P&L, rolled up by category.
///
/// Grouped on the engine rather than summed here: the category subtotals are
/// computed by `ReportRunner` from the item rows, so a subtotal can only ever
/// equal the sum of the rows above it. Pre-aggregating in SQL would mean two
/// independent summations of the same money, which is how a grouped total ends
/// up disagreeing with the grand total by a rounding rupee.
///
/// **`Ungrouped` is a real bucket and a big one.** Every item nobody has
/// classified lands there, which on a firm that has not used the category
/// feature is *every product*. That row is the honest answer and hiding it
/// would make the categorised rows look like the whole catalogue when they are
/// part of it. `Services` is separate again — see [itemCategoryNames].
const ReportSpec itemCategoryPnlSpec = ReportSpec(
  id: 'item_category_pnl',
  title: 'Item Category Wise P&L',
  category: 'Item/Stock',
  groupBy: ReportGroupBy.category,
  sort: ReportSort(columnKey: 'profit', descending: true),
  columns: [
    ReportColumn(key: 'category', label: 'Category', flex: 3, emphasise: true),
    ReportColumn(key: 'items', label: 'Items', kind: ReportValueKind.count),
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
      'Sale value is taxable value, before GST. Cost is what the goods that '
      'left cost, at the weighted moving average. Ungrouped holds every item '
      'with no category set; Services holds the items the firm bills as a '
      'service rather than a product.',
);

const ReportDefinition itemCategoryPnl = ReportDefinition(
  spec: itemCategoryPnlSpec,
  source: CallbackReportSource(
    sourceId: 'item_category_pnl',
    query: itemCategoryPnlRows,
    notes: _itemCategoryPnlNotes,
  ),
);

Future<List<ReportRow>> itemCategoryPnlRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedItemId(filters);
  final trading = await tradingByItem(db, firmId, window, selected: selected);
  final movements = await movementsByItem(
    db,
    firmId,
    window,
    selected: selected,
  );
  final items = await itemsById(db, firmId, trading.keys.toList());
  final categories = await itemCategoryNames(db, firmId, items);

  // `trading` is a map keyed by item id, so its iteration order is arbitrary —
  // the rows below come out in whatever order the hash produced.
  //
  // `ReportRunner.fold` sorts **only within a group**, by design ("a report that
  // sorts globally reorders the groups too, which reads as random when the
  // groups are months"), and the groups themselves keep source order. So this
  // report — titled "P&L", declaring `sort: profit descending` — printed its
  // category bands as `Ungrouped, Zebra, Alpha` for profits of 10, 9999 and
  // 500. `sale_purchase_by_party_group.dart` sorts its own rows for exactly
  // this reason; mirror it here.
  final rows = <ReportRow>[];
  final ordered = trading.entries.toList()
    ..sort((a, b) {
      final profitA =
          (a.value.saleValue -
                  (movements[a.key]?.outboundValue ?? Decimal.zero))
              .toDouble();
      final profitB =
          (b.value.saleValue -
                  (movements[b.key]?.outboundValue ?? Decimal.zero))
              .toDouble();
      return profitB.compareTo(profitA);
    });
  for (final entry in ordered) {
    final t = entry.value;
    if (t.isEmpty) continue;
    final info = items[entry.key];
    final cost = movements[entry.key]?.outboundValue ?? Decimal.zero;
    final sale = t.saleValue;
    final profit = sale - cost;
    final category = categories[entry.key] ?? 'Ungrouped';
    rows.add(
      ReportRow({
        // The group key is the **category cell**, so this column has to carry
        // the category and nothing else. Emitting the item name here and
        // grouping on this column silently collapses the whole report into one
        // band called after the first row's category.
        'category': category,
        'item': info?.name ?? '(deleted item)',
        'items': Decimal.one,
        'saleQty': t.saleQty,
        'sale': sale,
        'cost': cost,
        'profit': profit,
        'margin': marginPercent(profit, sale),
      }, label: category),
    );
  }
  return rows;
}

/// The same cost warning as Item Wise P&L, applied to **whole categories**.
///
/// A grouped report should not name every item in the firm that has never been
/// costed — that is a list of the catalogue, not a warning about this report.
/// So it fires only where a category's *entire* margin is unsupported, which is
/// the case where the reader is being shown something actively misleading rather
/// than something merely incomplete.
List<String> _itemCategoryPnlNotes(ReportResult result) {
  final suspect = <String>[];
  for (final group in result.groups) {
    if (group.label != null) continue;
    var sale = Decimal.zero;
    var cost = Decimal.zero;
    for (final row in group.rows) {
      sale += row.number(itemSaleColumn);
      cost += row.number(itemCostColumn);
    }
    if (sale > Decimal.zero && cost == Decimal.zero) suspect.add(group.name);
  }
  return uncostedNote(suspect);
}
