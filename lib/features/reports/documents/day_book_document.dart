import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/theme/app_sizes.dart';
import 'package:atria/shared/widgets/common_widgets.dart';
import 'package:atria/shared/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

/// **Day Book** — daily chronological register of receipts, payments, sales,
/// purchases, expenses, and cash/bank journal entries, grouped into daily
/// ledger cards with each day's Received, Paid, and Net cash movement.
Widget? buildDayBook(BuildContext context, ReportResult result) {
  if (result.rows.isEmpty) return null;

  final inflowCol = result.spec.columns.firstWhere((c) => c.key == 'inflow');
  final outflowCol = result.spec.columns.firstWhere((c) => c.key == 'outflow');

  final groups = result.groups.isNotEmpty
      ? result.groups
      : [ReportGroup(name: 'All Days', rows: result.rows.toList())];

  Decimal totalIn = Decimal.zero;
  Decimal totalOut = Decimal.zero;
  for (final row in result.rows) {
    totalIn += row.number(inflowCol);
    totalOut += row.number(outflowCol);
  }

  return Column(
    children: [
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.sm,
            AppSpace.xs,
            AppSpace.sm,
            16,
          ),
          itemCount: groups.length,
          separatorBuilder: (_, _) => const SizedBox(height: AppSpace.sm),
          itemBuilder: (context, index) {
            final group = groups[index];
            return _DayCard(
              group: group,
              inflowCol: inflowCol,
              outflowCol: outflowCol,
            );
          },
        ),
      ),
      _DayBookFooter(inflow: totalIn, outflow: totalOut),
    ],
  );
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.group,
    required this.inflowCol,
    required this.outflowCol,
  });

  final ReportGroup group;
  final ReportColumn inflowCol;
  final ReportColumn outflowCol;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dayIn = group.totalFor(inflowCol);
    final dayOut = group.totalFor(outflowCol);

    return AtriaCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Row(
              children: [
                Icon(
                  Icons.calendar_today_rounded,
                  size: 15,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    group.name,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ),
                _DaySummaryPill(label: 'In', amount: dayIn, isInflow: true),
                const SizedBox(width: 12),
                _DaySummaryPill(label: 'Out', amount: dayOut, isInflow: false),
              ],
            ),
          ),
          const Divider(height: 1),
          for (var i = 0; i < group.rows.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _DayEntryRow(
              row: group.rows[i],
              inflowCol: inflowCol,
              outflowCol: outflowCol,
            ),
          ],
        ],
      ),
    );
  }
}

class _DaySummaryPill extends StatelessWidget {
  const _DaySummaryPill({
    required this.label,
    required this.amount,
    required this.isInflow,
  });

  final String label;
  final Decimal amount;
  final bool isInflow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        MoneyText(
          amount,
          colorize: false,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: isInflow ? scheme.primary : scheme.error,
          ),
        ),
      ],
    );
  }
}

class _DayEntryRow extends StatelessWidget {
  const _DayEntryRow({
    required this.row,
    required this.inflowCol,
    required this.outflowCol,
  });

  final ReportRow row;
  final ReportColumn inflowCol;
  final ReportColumn outflowCol;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = '${row.cells['type'] ?? ''}';
    final number = '${row.cells['number'] ?? ''}';
    final party = '${row.cells['party'] ?? ''}';
    final reference = '${row.cells['reference'] ?? ''}';
    final inflow = row.number(inflowCol);
    final outflow = row.number(outflowCol);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      number.isEmpty ? type : '$type · $number',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                if (party.isNotEmpty || reference.isNotEmpty)
                  Text(
                    [
                      if (party.isNotEmpty) party,
                      if (reference.isNotEmpty) reference,
                    ].join(' — '),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 92,
            child: inflow == Decimal.zero
                ? const SizedBox.shrink()
                : MoneyText(
                    inflow,
                    colorize: false,
                    textAlign: TextAlign.right,
                    shrinkToFit: true,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: outflow == Decimal.zero
                ? const SizedBox.shrink()
                : MoneyText(
                    outflow,
                    colorize: false,
                    textAlign: TextAlign.right,
                    shrinkToFit: true,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DayBookFooter extends StatelessWidget {
  const _DayBookFooter({required this.inflow, required this.outflow});

  final Decimal inflow;
  final Decimal outflow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final net = inflow - outflow;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Net movement ${net.toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          MoneyText(
            inflow,
            colorize: false,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 16),
          MoneyText(
            outflow,
            colorize: false,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
