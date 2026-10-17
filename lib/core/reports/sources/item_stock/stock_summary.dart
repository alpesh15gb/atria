import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import 'item_common.dart';

/// **Stock summary** — what is on the shelf now, and what moved in the period.
///
/// The balance is `items.currentStock`, **not** the sum of the period's
/// movements. The two answer different questions and only one of them is "how
/// much have I got": the opening movement is stamped when the item was
/// *created*, so on anything created before the window it never appears inside
/// it, and a sum of movements would report an item the firm has stocked for
/// three years as having nothing at all.
///
/// **Services are excluded.** A service has no shelf; its stock is always zero
/// and listing it says only that the firm sells consulting.
///
/// **A negative balance is printed, not hidden.** The app deliberately allows
/// overselling, so a negative here is usually goods already promised and not yet
/// received. Suppressing it would make the report agree with the shelf rather
/// than with the books, which is the one thing a stock report must not do.
const ReportSpec stockSummarySpec = ReportSpec(
  id: 'stock_summary',
  title: 'Stock summary',
  category: 'Item/Stock',
  sort: ReportSort(columnKey: 'value', descending: true),
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
    ReportColumn(key: 'hsn', label: 'HSN', wideOnly: true, optional: true),
    ReportColumn(
      key: 'stock',
      label: 'In stock',
      kind: ReportValueKind.quantity,
      colorize: true,
    ),
    ReportColumn(key: 'in', label: 'In', kind: ReportValueKind.quantity),
    ReportColumn(key: 'out', label: 'Out', kind: ReportValueKind.quantity),
    ReportColumn(
      key: 'rate',
      label: 'Rate',
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
    ReportColumn(
      key: 'low',
      label: 'Reorder',
      kind: ReportValueKind.quantity,
      // Unset on every item in a catalogue that never set one — the default
      // state, and not a fault in the report.
      optional: true,
    ),
  ],
  footnote:
      'In stock is the item\'s current balance. In and Out are this period\'s '
      'movements only, and exclude the opening balance — which is recorded '
      'when the item is created, not at the start of this period. Rate and Stock '
      'value use the weighted moving average cost. Reorder shows the level set '
      'for the item; anything at or below it should be bought.',
);

const ReportDefinition stockSummary = ReportDefinition(
  spec: stockSummarySpec,
  source: CallbackReportSource(
    sourceId: 'stock_summary',
    query: stockSummaryRows,
    options: itemOptions,
    notes: _stockSummaryNotes,
  ),
);

Future<List<ReportRow>> stockSummaryRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedItemId(filters);
  final items = await allLiveItems(db, firmId, selected: selected);
  final categories = await itemCategoryNames(db, firmId, items);
  final movements = await movementsByItem(
    db,
    firmId,
    window,
    selected: selected,
  );
  final averages = await averageCostByItem(db, firmId, selected: selected);

  // Every item the firm still holds, even one with no movement in the period. A
  // stock summary listing only what moved is a report on the period, and the
  // question the reader actually has is "what have I got".
  final held = items.values.where(isStockKeeping).toList();
  final rows = <ReportRow>[];

  for (final item in held) {
    final info = infoFor(item);
    final m = movements[item.id] ?? ItemMovement.zero;
    // Valued at today's moving average. Where no average exists — an item that
    // has never had a costed receipt, or one whose receipts all predate
    // costing — the master's purchase price stands in, because a zero-valued
    // row reads as "this stock is worthless" and that is a claim the report
    // cannot support.
    final rate = averages[item.id] ?? info.purchasePrice;
    rows.add(
      ReportRow({
        'item': info.name,
        'category': categories[item.id] ?? 'Ungrouped',
        'unit': info.unit,
        'hsn': info.hsn,
        'stock': info.currentStock,
        'in': m.inboundQty,
        'out': m.outboundQty,
        'rate': rate,
        'value': info.currentStock > Decimal.zero
            ? info.currentStock * rate
            : Decimal.zero,
        // The reorder level, and only when one is set — a zero here would read
        // as "reorder at zero" and put every item on a purchase list.
        'low': info.lowStockAlert > Decimal.zero ? info.lowStockAlert : '',
      }, label: info.name),
    );
  }
  return rows;
}

List<String> _stockSummaryNotes(ReportResult result) {
  final uncosted = <String>[];
  for (final row in result.rows) {
    final stock = row.number(_stockColumn);
    final rate = row.number(_rateColumn);
    if (stock != Decimal.zero && rate == Decimal.zero) {
      uncosted.add(row.text(_itemColumn));
    }
  }
  return uncostedNote(uncosted);
}

const ReportColumn _stockColumn = ReportColumn(
  key: 'stock',
  label: 'In stock',
  kind: ReportValueKind.quantity,
);
const ReportColumn _rateColumn = ReportColumn(
  key: 'rate',
  label: 'Rate',
  kind: ReportValueKind.rate,
);
const ReportColumn _itemColumn = ReportColumn(key: 'item', label: 'Item');
