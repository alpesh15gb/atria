import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/theme/app_sizes.dart';
import 'package:atria/shared/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

/// **Cash flow**, drawn with the running balance the source computed.
///
/// This one is a document mainly because of the **Balance** column. It is a
/// running total down the right-hand side, and it is the figure a reader checks
/// against the bank statement at the end of the month — so it is printed as a
/// distinct banded column rather than another grey number in a row.
///
/// **The balance is the source's, not recomputed here.** The source computes it
/// over the merged cash/bank/cheques stream, which is a different number from
/// any single account's ledger balance. Recomputing per-account here would put a
/// different balance on the screen than the export carries.
Widget? buildCashFlow(BuildContext context, ReportResult result) {
  if (result.rows.isEmpty) return null;

  final inflow = result.spec.columns.firstWhere((c) => c.key == 'inflow');
  final outflow = result.spec.columns.firstWhere((c) => c.key == 'outflow');
  final closing = result.spec.columns.firstWhere((c) => c.key == 'closing');

  var totalIn = Decimal.zero;
  var totalOut = Decimal.zero;
  for (final row in result.rows) {
    totalIn += row.number(inflow);
    totalOut += row.number(outflow);
  }

  final months = result.groups.isEmpty ? [null] : result.groups;
  return Column(
    children: [
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
          itemCount: months.length,
          itemBuilder: (context, index) {
            final group = months[index];
            final rows = group?.rows ?? result.rows;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (group != null) _MonthHeading(name: group.name),
                for (final row in rows)
                  _FlowRow(
                    particulars: '${row.cells['particulars'] ?? ''}',
                    reference: '${row.cells['reference'] ?? ''}',
                    inflow: row.number(inflow),
                    outflow: row.number(outflow),
                    closing: row.number(closing),
                    // The closing of the last row of a block is the block's
                    // balance, taken from the source rather than re-added —
                    // and it is printed because a running balance nobody can
                    // see the end of is not a running balance.
                    isLast:
                        index == months.length - 1 &&
                        rows.isNotEmpty &&
                        rows.last == row,
                  ),
              ],
            );
          },
        ),
      ),
      _Totals(inflow: totalIn, outflow: totalOut),
    ],
  );
}

class _MonthHeading extends StatelessWidget {
  const _MonthHeading({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.sm, bottom: 2),
      child: Text(
        name,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _FlowRow extends StatelessWidget {
  const _FlowRow({
    required this.particulars,
    required this.reference,
    required this.inflow,
    required this.outflow,
    required this.closing,
    required this.isLast,
  });

  final String particulars;
  final String reference;
  final Decimal inflow;
  final Decimal outflow;
  final Decimal closing;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodyMedium;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: isLast ? scheme.surfaceContainerHighest : null,
        border: const Border(
          bottom: BorderSide(color: Colors.black12, width: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  particulars,
                  style: style,
                  overflow: TextOverflow.ellipsis,
                ),
                // The reference is the second line rather than a fourth column,
                // because a cheque number is only ever read *under* the
                // particular it belongs to.
                if (reference.isNotEmpty)
                  Text(
                    reference,
                    style: style?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          SizedBox(width: 64, child: _figure(context, inflow, style)),
          SizedBox(width: 64, child: _figure(context, outflow, style)),
          SizedBox(
            width: 88,
            child: MoneyText(
              closing,
              style: style?.copyWith(
                fontWeight: isLast ? FontWeight.w700 : FontWeight.w500,
              ),
              textAlign: TextAlign.right,
              shrinkToFit: true,
            ),
          ),
        ],
      ),
    );
  }

  static Widget _figure(
    BuildContext context,
    Decimal amount,
    TextStyle? style,
  ) => amount == Decimal.zero
      // A nil column entry is left blank rather than printed as ₹0.00, and
      // the reason is not tidiness: a column of mostly zeros is a column the
      // reader has to scan past on every row to find the one figure they
      // came for. Blank means "nothing this way"; a zero means "something
      // that happens to be nothing", which is not the same claim.
      ? const SizedBox.shrink()
      : MoneyText(
          amount,
          style: style,
          textAlign: TextAlign.right,
          shrinkToFit: true,
        );
}

class _Totals extends StatelessWidget {
  const _Totals({required this.inflow, required this.outflow});

  final Decimal inflow;
  final Decimal outflow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.titleSmall
        ?.copyWith(fontWeight: FontWeight.w700);
    final net = inflow - outflow;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              'Net movement ${_plain(net)}',
              style: style?.copyWith(
                color: net < Decimal.zero ? scheme.error : scheme.primary,
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: MoneyText(
              inflow,
              style: style,
              textAlign: TextAlign.right,
              shrinkToFit: true,
            ),
          ),
          SizedBox(
            width: 64,
            child: MoneyText(
              outflow,
              style: style,
              textAlign: TextAlign.right,
              shrinkToFit: true,
            ),
          ),
          const SizedBox(width: 88),
        ],
      ),
    );
  }
}

String _plain(Decimal value) => value.round(scale: 2).toStringAsFixed(2);
