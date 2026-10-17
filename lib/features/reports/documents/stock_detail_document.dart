import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../../core/reports/engine/report_result.dart';
import '../../../core/reports/spec/report_spec.dart';
import '../../../shared/widgets/common_widgets.dart';

/// **Stock Detail** as a ledger — one card per item, its movements in order.
///
/// A bespoke body because the report is a **running balance**. The same rows in
/// the shared grid would be a list of quantities the reader has to accumulate
/// themselves, which is the one thing the Balance column exists to do. Here the
/// running figure is bold and sits at the right, and a movement that took stock
/// away is marked so the eye can follow the balance down.
///
/// **Grouped by item, not by date.** A date-ordered stock ledger interleaves
/// every product, so a reader tracking one item's balance has to pick its rows
/// out of the lot. Per-item blocks are what makes the column checkable.
Widget buildStockDetail(BuildContext context, ReportResult result) {
  // `ReportGroupBy` was not used here because the source emits one row per
  // movement and the engine's grouping would insert subtotal rows into a ledger
  // where a subtotal is meaningless — there is no total quantity of a balance.
  final blocks = <String, List<ReportRow>>{};
  final order = <String>[];
  for (final row in result.rows) {
    // Keyed on the item **id**, with the printed name as the heading.
    //
    // It used to key on `row.text(_itemColumn)` — the name — so two genuinely
    // different items sharing a name (an IT bag and a cement bag; a 25 kg and a
    // 50 kg variant both typed as "Cement 50") merged into one card. That card's
    // header then printed `rows.last`'s balance, which belongs to whichever item
    // happened to sort last and to neither the reader's intent nor reliably to
    // the block. Per-item cards exist so one balance can be followed down; a
    // duplicate name breaks exactly that.
    final key = (row.cells[_itemIdColumn.key] ?? row.text(_itemColumn))
        .toString();
    if (!blocks.containsKey(key)) order.add(key);
    (blocks[key] ??= <ReportRow>[]).add(row);
  }

  if (blocks.isEmpty) {
    return Center(
      child: Text(
        'No stock movements in this period.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  return ListView.separated(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
    itemCount: order.length,
    separatorBuilder: (_, _) => const SizedBox(height: 12),
    itemBuilder: (context, index) {
      final key = order[index];
      final rows = blocks[key]!;
      final heading = rows.first.text(_itemColumn);
      return AtriaCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      heading,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    // The closing figure of the block, taken from its last row
                    // rather than summed: a balance is a level, and summing
                    // balances would total the arithmetic rather than the stock.
                    'Balance ${rows.last.text(_balanceColumn)}',
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            for (final row in rows) _movementRow(context, row),
          ],
        ),
      );
    },
  );
}

Widget _movementRow(BuildContext context, ReportRow row) {
  final qty = row.number(_qtyColumn);
  final out = qty < Decimal.zero;
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(
            _dateLabel(row.cells[_dateColumn.key]),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.text(_kindColumn),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (row.text(_numberColumn).isNotEmpty)
                Text(
                  row.text(_numberColumn),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        // Red for stock leaving. Here a negative is not an error — it is a
        // sale, and colouring it as one is the reason this row is marked rather
        // than left to be inferred from the sign.
        Text(
          '${out ? '−' : '+'}${row.text(_qtyColumn).replaceFirst('-', '')}',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: out
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        SizedBox(
          width: 84,
          child: Text(
            row.text(_balanceColumn),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    ),
  );
}

/// A short date, since the ledger is already ordered and the year repeats.
///
/// Takes the **raw cell**, not `row.text()`. `ReportRow.text()` renders a
/// `date`-kind column as `dd-mm-yyyy`, but this used to be handed that string
/// and sliced it as though it were `yyyy-mm-dd` — so `09-04-2026` came out as
/// `26 -2` on every row of every card. Reading the `DateTime` itself is the
/// fix that cannot drift from the format `text()` happens to use today.
String _dateLabel(Object? cell) {
  if (cell is DateTime) {
    return '${cell.day.toString().padLeft(2, '0')} '
        '${cell.month.toString().padLeft(2, '0')}';
  }
  return cell?.toString() ?? '';
}

const ReportColumn _itemColumn = ReportColumn(key: 'item', label: 'Item');
const ReportColumn _itemIdColumn =
    ReportColumn(key: 'itemId', label: 'Item ID', wideOnly: true);
const ReportColumn _dateColumn = ReportColumn(
  key: 'date',
  label: 'Date',
  kind: ReportValueKind.date,
);
const ReportColumn _kindColumn = ReportColumn(key: 'kind', label: 'Type');
const ReportColumn _numberColumn = ReportColumn(
  key: 'number',
  label: 'Document',
);
const ReportColumn _qtyColumn = ReportColumn(
  key: 'qty',
  label: 'Qty',
  kind: ReportValueKind.quantity,
);
const ReportColumn _balanceColumn = ReportColumn(
  key: 'balance',
  label: 'Balance',
  kind: ReportValueKind.quantity,
);
