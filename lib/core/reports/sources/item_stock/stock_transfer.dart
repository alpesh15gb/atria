import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:drift/drift.dart';

import 'item_common.dart';

/// **Stock Transfer Report** — movements between godowns.
///
/// **A null `godownId` is a location, not an absence of one.** A firm with a
/// single shop never creates a godown row, and every one of its movements
/// carries null. Reading null as "unknown" would report a one-shop business as
/// having no transfer history at all — technically true and completely useless
/// — so null is labelled `Main` and the row still appears.
///
/// **The two sides of a transfer are two rows**, not one row with in and out
/// columns. That is forced by the schema: a transfer writes two movements, one
/// leaving and one arriving, and nothing on either row names the other. Pairing
/// them would need a transfer id the table does not have, and inventing one
/// would be a guess. So the report says what moved and which way, which is
/// checkable against the stock of each godown, and does not claim a pairing it
/// cannot support.
///
/// **Kinds other than `transfer_in`/`transfer_out` are excluded.** Only a
/// transfer is a movement between locations. A sale leaves stock from wherever
/// the firm happens to hold it and is not a transfer, and listing it here would
/// make a godown's receipts and issues balance against nothing.
const ReportSpec stockTransferSpec = ReportSpec(
  id: 'stock_transfer',
  title: 'Stock Transfer Report',
  category: 'Item/Stock',
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
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(key: 'item', label: 'Item', flex: 3, emphasise: true),
    ReportColumn(key: 'direction', label: 'Direction'),
    ReportColumn(key: 'godown', label: 'Godown', flex: 2),
    ReportColumn(key: 'qty', label: 'Qty', kind: ReportValueKind.quantity),
    ReportColumn(key: 'rate', label: 'Rate', kind: ReportValueKind.rate),
    ReportColumn(
      key: 'value',
      label: 'Value',
      kind: ReportValueKind.money,
      emphasise: true,
      colorize: true,
    ),
    ReportColumn(key: 'number', label: 'Reference', wideOnly: true),
  ],
  footnote:
      'Only movements between godowns appear — sales and purchases are not '
      'transfers. A firm with one location records no godown and is shown as '
      'Main. The two halves of a transfer are two rows; they are not paired '
      'because nothing in the ledger records which movement is the other end of '
      'which.',
);

const ReportDefinition stockTransfer = ReportDefinition(
  spec: stockTransferSpec,
  source: CallbackReportSource(
    sourceId: 'stock_transfer',
    query: stockTransferRows,
    options: itemOptions,
  ),
);

/// The name used for a firm that has never created a godown.
const String defaultGodownLabel = 'Main';

Future<List<ReportRow>> stockTransferRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedItemId(filters);
  final movements = db.stockMovements;
  final query = db.select(movements)
    ..where(
      (_) =>
          movements.firmId.equals(firmId) &
          ReportFilters.within(movements.date, window) &
          itemScope(movements.itemId, selected) &
          movements.kind.isIn(const ['transfer_in', 'transfer_out']),
    )
    ..orderBy([(m) => OrderingTerm.asc(m.date), (m) => OrderingTerm.asc(m.id)]);

  final rows = await query.get();
  if (rows.isEmpty) return const [];

  final items = await itemsById(db, firmId, rows.map((r) => r.itemId).toList());
  final godownIds = rows
      .map((r) => r.godownId)
      .whereType<String>()
      .toSet()
      .toList();
  final godownNames = await godownNameMap(db, firmId, godownIds);

  return [
    for (final m in rows)
      ReportRow({
        'date': m.date,
        'item': items[m.itemId]?.name ?? '(deleted item)',
        'direction': m.kind == 'transfer_in' ? 'In' : 'Out',
        'godown': godownNames[m.godownId] ?? defaultGodownLabel,
        // Absolutised for the same reason `movementsByItem` does: the sign is
        // carried by the Direction column, and a reader scanning the Qty column
        // should see how much moved, not how it is stored.
        'qty': dec(m.quantity).abs(),
        'rate': dec(m.unitCost),
        'value': dec(m.quantity).abs() * dec(m.unitCost),
        'number': m.sourceNumber ?? '',
      }, label: items[m.itemId]?.name ?? m.itemId),
  ];
}

/// Godown names by id.
///
/// Null entries are simply absent from the map, and the caller substitutes
/// [defaultGodownLabel] — so an archived godown still shows its own name rather
/// than being relabelled as the main store.
Future<Map<String, String>> godownNameMap(
  AppDatabase db,
  String firmId,
  List<String> ids,
) async {
  if (ids.isEmpty) return const {};
  final query = db.select(db.godowns)
    ..where((g) => g.firmId.equals(firmId) & g.id.isIn(ids));
  return {for (final godown in await query.get()) godown.id: godown.name};
}
