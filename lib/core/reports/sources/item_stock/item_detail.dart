import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import 'item_common.dart';

/// **Item Detail** — the item master, with the period's trading beside it.
///
/// The only report in the folder that is *about the item itself* rather than
/// about its movements. Everything else answers a question about a period; this
/// one answers "what did we set up for this product, and how did it do".
///
/// **It lists every live item, including ones with no movement.** It is the
/// catalogue with performance attached, and a catalogue entry that quietly
/// disappears because it sold nothing is a catalogue the reader cannot trust to
/// be complete.
///
/// **A service is a real row here.** It has no stock and no cost, and its
/// absence from a stock report is a stock fact — but a firm that bills hours
/// needs to see its hours on the same screen as its goods, and that is exactly
/// what a merged `Ungrouped`/`Services` bucket on the category reports cannot
/// do. The Stock column says `Service` rather than zero, because "0 in stock"
/// and "not applicable" are different answers.
const ReportSpec itemDetailSpec = ReportSpec(
  id: 'item_detail',
  title: 'Item Detail',
  category: 'Item/Stock',
  sort: ReportSort(columnKey: 'item', descending: false),
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
    ReportColumn(key: 'sku', label: 'SKU', wideOnly: true, optional: true),
    ReportColumn(key: 'category', label: 'Category', optional: true),
    ReportColumn(key: 'unit', label: 'Unit'),
    ReportColumn(key: 'hsn', label: 'HSN/SAC', optional: true),
    ReportColumn(
      key: 'stock',
      label: 'In stock',
      kind: ReportValueKind.quantity,
    ),
    ReportColumn(
      key: 'salePrice',
      label: 'Sale price',
      kind: ReportValueKind.rate,
    ),
    ReportColumn(
      key: 'purchasePrice',
      label: 'Purchase price',
      kind: ReportValueKind.rate,
    ),
    ReportColumn(key: 'sale', label: 'Sold for', kind: ReportValueKind.money),
    ReportColumn(key: 'saleQty', label: 'Sold', kind: ReportValueKind.quantity),
    ReportColumn(
      key: 'purchase',
      label: 'Bought for',
      kind: ReportValueKind.money,
    ),
    ReportColumn(key: 'type', label: 'Type'),
  ],
  footnote:
      'Every item the firm still sells, whether or not it traded in this '
      'period. Sale price and Purchase price are the item master\'s current '
      'figures — the period\'s actual figures are Sold for and Bought for. '
      'A service shows no stock, because it has none.',
);

const ReportDefinition itemDetail = ReportDefinition(
  spec: itemDetailSpec,
  source: CallbackReportSource(
    sourceId: 'item_detail',
    query: itemDetailRows,
    options: itemOptions,
  ),
);

Future<List<ReportRow>> itemDetailRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedItemId(filters);
  final items = await allLiveItems(db, firmId, selected: selected);
  final categories = await itemCategoryNames(db, firmId, items);
  final trading = await tradingByItem(db, firmId, window, selected: selected);

  final rows = <ReportRow>[];
  for (final item in items.values) {
    final info = infoFor(item);
    final t = trading[item.id] ?? ItemTrading.zero;
    rows.add(
      ReportRow({
        'item': info.name,
        'sku': info.sku,
        'category': categories[item.id] ?? 'Ungrouped',
        'unit': info.unit,
        'hsn': info.hsn,
        // Text, not a number: a zero here would read as "nothing in stock",
        // which is a false statement about a service.
        'stock': info.isService
            ? 'Service'
            : isStockKeeping(item)
            ? info.currentStock
            : Decimal.zero,
        'salePrice': info.salePrice,
        'purchasePrice': info.purchasePrice,
        'sale': t.saleValue,
        'saleQty': t.saleQty,
        'purchase': t.purchaseValue,
        'type': _itemType(item, info),
      }, label: info.name),
    );
  }
  return rows;
}

/// What kind of thing this is, in the words the firm uses.
///
/// [ItemInfo] does not carry `stockType`, so this is the one place the report
/// reads it off the entity — and it passes the code through **as stored** when
/// it is not one of the two known ones. `stockType` is free text, so flattening
/// an unrecognised value into "Product" would quietly erase a distinction the
/// firm made: some catalogues distinguish counted goods from goods received but
/// not tallied, and the whole point of this column is to show which is which.
String _itemType(ItemEntity item, ItemInfo info) {
  if (info.isService) return 'Service';
  return switch (item.stockType) {
    'tracked' => 'Stock item',
    'non_tracked' || 'non-tracked' => 'Non-stock',
    final other => other.isEmpty ? 'Product' : other,
  };
}
