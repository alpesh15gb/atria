import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/theme/app_sizes.dart';
import 'package:atria/shared/widgets/common_widgets.dart';
import 'package:atria/shared/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

/// **GSTR-9** — the annual return (Part II & Part III ITC), drawn as structured
/// schedule sections with post-filing adjustments clearly separated.
Widget? buildGstr9(BuildContext context, ReportResult result) {
  if (result.rows.isEmpty) return null;

  final amountCol = result.spec.columns.firstWhere((c) => c.key == 'amount');

  final partTwoOutward = <ReportRow>[];
  final partThreeItc = <ReportRow>[];
  final adjustmentRows = <ReportRow>[];

  for (final row in result.rows) {
    final table = '${row.cells['table'] ?? ''}';
    final desc = '${row.cells['description'] ?? ''}';
    if (desc.startsWith('Adjustment')) {
      adjustmentRows.add(row);
    } else if (table.startsWith('6')) {
      partThreeItc.add(row);
    } else {
      partTwoOutward.add(row);
    }
  }

  Decimal outwardTax = Decimal.zero;
  Decimal netItc = Decimal.zero;
  for (final row in partTwoOutward) {
    if ('${row.cells['table']}' == '4A') {
      outwardTax = row.number(amountCol);
    }
  }
  for (final row in partThreeItc) {
    if ('${row.cells['table']}' == '6C') {
      netItc = row.number(amountCol);
    }
  }

  return SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.sm,
      AppSpace.xs,
      AppSpace.sm,
      96,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Gstr9SummaryBanner(outwardTax: outwardTax, netItc: netItc),
        const SizedBox(height: AppSpace.sm),
        if (partTwoOutward.isNotEmpty)
          _Gstr9ScheduleCard(
            title:
                'Part II — Details of Outward and Inward Supplies Made During the Financial Year (Table 4)',
            rows: partTwoOutward,
            amountCol: amountCol,
          ),
        if (adjustmentRows.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          _Gstr9ScheduleCard(
            title: 'Post-Filing Annual Adjustments (Tables 4 / 6 / 8 / 9)',
            rows: adjustmentRows,
            amountCol: amountCol,
            colorizeSign: true,
          ),
        ],
        if (partThreeItc.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          _Gstr9ScheduleCard(
            title:
                'Part III — Details of ITC for the Financial Year (Table 6)',
            rows: partThreeItc,
            amountCol: amountCol,
            highlightTable: '6C',
          ),
        ],
      ],
    ),
  );
}

class _Gstr9SummaryBanner extends StatelessWidget {
  const _Gstr9SummaryBanner({
    required this.outwardTax,
    required this.netItc,
  });

  final Decimal outwardTax;
  final Decimal netItc;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      padding: const EdgeInsets.all(14),
      background: scheme.primaryContainer.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'GSTR-9 Annual Return Summary',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Annual Output Tax (4A)',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    MoneyText(
                      outwardTax,
                      colorize: false,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Annual Net ITC (6C)',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    MoneyText(
                      netItc,
                      colorize: false,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Gstr9ScheduleCard extends StatelessWidget {
  const _Gstr9ScheduleCard({
    required this.title,
    required this.rows,
    required this.amountCol,
    this.highlightTable,
    this.colorizeSign = false,
  });

  final String title;
  final List<ReportRow> rows;
  final ReportColumn amountCol;
  final String? highlightTable;
  final bool colorizeSign;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Divider(height: 1),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _buildRow(context, rows[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, ReportRow row) {
    final scheme = Theme.of(context).colorScheme;
    final table = '${row.cells['table'] ?? ''}';
    final description = '${row.cells['description'] ?? ''}';
    final amount = row.number(amountCol);
    final isHighlighted = table == highlightTable;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: isHighlighted
          ? scheme.primaryContainer.withValues(alpha: 0.45)
          : null,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: isHighlighted
                  ? scheme.primary
                  : scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              table,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: isHighlighted
                    ? scheme.onPrimary
                    : scheme.onSecondaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: isHighlighted ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 12),
          MoneyText(
            amount,
            colorize: colorizeSign || amount < Decimal.zero,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: isHighlighted ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
