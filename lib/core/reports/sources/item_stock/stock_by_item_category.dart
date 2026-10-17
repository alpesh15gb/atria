import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import 'item_common.dart';

/// **Stock Summary Report By Item Category** — the stock position, by category.
///
/// The Stock summary report's roll-up. Same figures, grouped — which is the
/// question a shopkeeper actually asks about a category ("how much money is in
/// the cement") rather than about a product.
///
/// **Services are excluded.** A service has no stock and no shelf, so a
/// category valuation containing one is a row of zeros claiming that consulting
/// work is worth nothing. `Services` as a category exists so the *P&L* and the
/// *sales* reports can file a service somewhere; here it would be a
/// contradiction on the face of the report.
const ReportSpec stockByItemCategorySpec = ReportSpec(
  id: 'stock_by_item_category',
  title: 'Stock Summary Report By Item Category',
  category: 'Item/Stock',
  groupBy: ReportGroupBy.category,
  sort: ReportSort(columnKey: 'value', descending: true),
  columns: [
    ReportColumn(key: 'category', label: 'Category', flex: 3, emphasise: true),
    ReportColumn(key: 'items', label: 'Items', kind: ReportValueKind.count),
    ReportColumn(
      key: 'quantity',
      label: 'Quantity',
      kind: ReportValueKind.quantity,
    ),
    ReportColumn(
      key: 'average',
      label: 'Average rate',
      kind: ReportValueKind.rate,
      wideOnly: true,
    ),
    ReportColumn(
      key: 'value',
      label: 'Stock value',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
  ],
  footnote:
      'A stock position as at today, not a period total. Value uses the '
      'weighted moving average cost. Items counts the catalogue entries in the '
      'category, including any with nothing on the shelf.',
);

const ReportDefinition stockByItemCategory = ReportDefinition(
  spec: stockByItemCategorySpec,
  source: CallbackReportSource(
    sourceId: 'stock_by_item_category',
    query: stockByItemCategoryRows,
  ),
);

Future<List<ReportRow>> stockByItemCategoryRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final items = await allLiveItems(db, firmId);
  final held = items.values.where(isStockKeeping).toList();
  if (held.isEmpty) return const [];
  final categories = await itemCategoryNames(db, firmId, items);
  final averages = await averageCostByItem(db, firmId);

  final rows = <ReportRow>[];
  for (final item in held) {
    final info = infoFor(item);
    final rate = averages[item.id] ?? info.purchasePrice;
    rows.add(
      ReportRow({
        // The group key is the category cell, so this column must carry the
        // category — the item name would collapse the report into one band.
        'category': categories[item.id] ?? 'Ungrouped',
        'item': info.name,
        'items': Decimal.one,
        'quantity': info.currentStock,
        'average': rate,
        'value': info.currentStock > Decimal.zero
            ? info.currentStock * rate
            : Decimal.zero,
      }, label: categories[item.id] ?? 'Ungrouped'),
    );
  }
  return rows;
}
