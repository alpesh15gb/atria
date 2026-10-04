import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import 'item_common.dart';

/// **Low Stock Summary** — what has fallen to or below its reorder level.
///
/// **An item with no reorder level is never on this report.** `lowStockAlert`
/// defaults to zero, and zero is not "reorder when I reach zero" — it is "no
/// level has been set". Reading it as a threshold puts every item in a firm
/// that has never configured reorder levels onto the report, and a Low Stock
/// Summary listing the entire catalogue is a screen nobody opens. This is the
/// single easiest thing to get wrong in the folder and [ItemInfo.isLowStock] is
/// where the rule lives so all of them obey it.
///
/// **It is a stock report, not a period report**, so it says nothing about the
/// window and its columns are all balances. The window toolbar still shows
/// because the screen's chrome is shared, and the title says what it is.
///
/// **Shortfall is what to buy, and it is negative-to-zero.** The reader's
/// action is to purchase the gap, and a report that shows only "12 in stock"
/// leaves that arithmetic to them on every row.
const ReportSpec lowStockSummarySpec = ReportSpec(
  id: 'low_stock_summary',
  title: 'Low Stock Summary',
  category: 'Item/Stock',
  subtitle: 'Items at or below their reorder level — a stock position, not a period',
  sort: ReportSort(columnKey: 'stock', descending: false),
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
    ReportColumn(key: 'unit', label: 'Unit'),
    ReportColumn(key: 'hsn', label: 'HSN', wideOnly: true),
    ReportColumn(key: 'stock', label: 'In stock', kind: ReportValueKind.quantity),
    ReportColumn(
      key: 'reorder',
      label: 'Reorder level',
      kind: ReportValueKind.quantity,
    ),
    ReportColumn(
      key: 'shortfall',
      label: 'Buy',
      kind: ReportValueKind.quantity,
      flex: 2,
      emphasise: true,
    ),
    ReportColumn(
      key: 'rate',
      label: 'Rate',
      kind: ReportValueKind.rate,
      wideOnly: true,
    ),
    ReportColumn(
      key: 'cost',
      label: 'To buy',
      kind: ReportValueKind.money,
      emphasise: true,
    ),
  ],
  footnote:
      'Only items with a reorder level set are listed — an item with no level is '
      'not low, it is unconfigured. Buy is the shortfall, and is zero once the '
      'stock reaches the level. In stock is the current balance, not the '
      'period\'s movements.',
);

const ReportDefinition lowStockSummary = ReportDefinition(
  spec: lowStockSummarySpec,
  source: CallbackReportSource(
    sourceId: 'low_stock_summary',
    query: lowStockSummaryRows,
    options: itemOptions,
  ),
);

Future<List<ReportRow>> lowStockSummaryRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedItemId(filters);
  final items = await allLiveItems(db, firmId, selected: selected);
  final categories = await itemCategoryNames(db, firmId, items);
  final averages = await averageCostByItem(db, firmId, selected: selected);

  final rows = <ReportRow>[];
  for (final item in items.values) {
    // Services cannot be low: there is no shelf to run out of. The rule lives in
    // `isLowStock` and this report does not re-derive it.
    if (!isStockKeeping(item)) continue;
    final info = infoFor(item);
    if (!info.isLowStock) continue;
    final shortfall = info.lowStockAlert - info.currentStock;
    final rate = averages[item.id] ?? info.purchasePrice;
    rows.add(
      ReportRow({
        'item': info.name,
        'category': categories[item.id] ?? 'Ungrouped',
        'unit': info.unit,
        'hsn': info.hsn,
        'stock': info.currentStock,
        'reorder': info.lowStockAlert,
        // Reached or passed, there is nothing to buy. Showing a negative "Buy"
        // would have the reader order stock they already have.
        'shortfall': shortfall > Decimal.zero ? shortfall : Decimal.zero,
        'rate': rate,
        'cost': (shortfall > Decimal.zero ? shortfall : Decimal.zero) * rate,
      }, label: info.name),
    );
  }
  return rows;
}
