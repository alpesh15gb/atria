import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import 'item_common.dart';

/// **Sale/Purchase Report By Item Category** — trading, by category.
///
/// Both sides of the trading figures on one row per category, which is what
/// makes the pair readable: a category's sales beside its purchases is a
/// turnover, and the two columns apart are the two numbers a reader would
/// otherwise have to add up in their head.
///
/// **Services are included.** They are billed and they are trading, and a
/// service business's entire turnover would otherwise be absent from its own
/// turnover report. They carry no cost, which the margin column reports as a
/// zero-margin rather than by dropping the row.
///
/// **Not netted into one "value" column.** Sale and purchase figures stay on
/// their own sides. A single netted figure is arithmetically available and
/// operationally useless — a category that sold ₹5L and bought ₹5L is a busy
/// category, not a category worth zero.
const ReportSpec spByItemCategorySpec = ReportSpec(
  id: 'sp_by_item_category',
  title: 'Sale/Purchase Report By Item Category',
  category: 'Item/Stock',
  groupBy: ReportGroupBy.category,
  sort: ReportSort(columnKey: 'sale', descending: true),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kItemFilterId,
      label: 'Item',
      value: null,
      hint: 'Every item',
    ),
  ],
  columns: [
    ReportColumn(key: 'category', label: 'Category', flex: 3, emphasise: true),
    ReportColumn(key: 'items', label: 'Items', kind: ReportValueKind.count),
    ReportColumn(key: 'saleQty', label: 'Sold', kind: ReportValueKind.quantity),
    ReportColumn(key: 'sale', label: 'Sale value', kind: ReportValueKind.money),
    ReportColumn(
      key: 'purchaseQty',
      label: 'Bought',
      kind: ReportValueKind.quantity,
    ),
    ReportColumn(
      key: 'purchase',
      label: 'Purchase value',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'cost',
      label: 'Cost of goods sold',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'profit',
      label: 'Profit',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
  ],
  footnote:
      'Sale and purchase values are taxable, before GST. Cost is what the '
      'goods that left cost, at the weighted moving average — not what was '
      'bought, since stock still held is an asset rather than an expense. '
      'Services appear and carry no cost.',
);

const ReportDefinition spByItemCategory = ReportDefinition(
  spec: spByItemCategorySpec,
  source: CallbackReportSource(
    sourceId: 'sp_by_item_category',
    query: spByItemCategoryRows,
    options: itemOptions,
  ),
);

Future<List<ReportRow>> spByItemCategoryRows(
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

  final rows = <ReportRow>[];
  for (final entry in trading.entries) {
    final t = entry.value;
    if (t.isEmpty) continue;
    final category = categories[entry.key] ?? 'Ungrouped';
    final cost = movements[entry.key]?.outboundValue ?? Decimal.zero;
    rows.add(
      ReportRow({
        'category': category,
        'item': items[entry.key]?.name ?? '(deleted item)',
        'items': Decimal.one,
        'saleQty': t.saleQty,
        'sale': t.saleValue,
        'purchaseQty': t.purchaseQty,
        'purchase': t.purchaseValue,
        'cost': cost,
        'profit': t.saleValue - cost,
      }, label: category),
    );
  }
  return rows;
}
