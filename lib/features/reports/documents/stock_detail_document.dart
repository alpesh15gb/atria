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
    final name = row.text(_itemColumn);
    if (!blocks.containsKey(name)) order.add(name);
    (blocks[name] ??= <ReportRow>[]).add(row);
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
      final name = order[index];
      final rows = blocks[name]!;
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
                      name,
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
            _dateLabel(row.text(_dateColumn)),
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
String _dateLabel(String iso) =>
    iso.length >= 10 ? '${iso.substring(8, 10)} ${iso.substring(5, 7)}' : iso;

const ReportColumn _itemColumn = ReportColumn(key: 'item', label: 'Item');
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
