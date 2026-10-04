import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/theme/app_sizes.dart';
import 'package:atria/shared/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../report_document_view.dart';

/// **Balance Sheet**, drawn as two stacked columns with the equation at the
/// foot.
///
/// The equation is the reason this is bespoke. A balance sheet's entire claim
/// is `assets = liabilities + equity`, and in a grid that claim exists nowhere
/// on the page — it is three groups of rows with subtotals, and the reader has
/// to notice it themselves. Here it is stated, with the difference printed
/// either as nil or as a figure.
///
/// **Liabilities and capital are shown positive**, because the source already
/// flips them and a sheet of negative liabilities is a sheet nobody can add up
/// in their head. The widget does not re-sign anything.
Widget? buildBalanceSheet(BuildContext context, ReportResult result) {
  if (result.rows.isEmpty) return null;

  final amount = result.spec.columns.firstWhere((c) => c.key == 'amount');
  final assets = _sectionFor(result, 'Assets', amount);
  final liabilities = _sectionFor(result, 'Liabilities', amount);
  final equity = _sectionFor(result, 'Equity', amount);

  if (assets.isEmpty && liabilities.isEmpty && equity.isEmpty) return null;

  final assetTotal = _totalOf(assets);
  final liabilityTotal = _totalOf(liabilities);
  final equityTotal = _totalOf(equity);
  final difference = assetTotal - liabilityTotal - equityTotal;

  return SingleChildScrollView(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpace.sm,
      vertical: AppSpace.xs,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          title: 'Assets',
          groups: assets,
          total: assetTotal,
          amount: amount,
        ),
        _Section(
          title: 'Liabilities',
          groups: liabilities,
          total: liabilityTotal,
          amount: amount,
        ),
        _Section(
          title: 'Equity',
          groups: equity,
          total: equityTotal,
          amount: amount,
        ),
        const SizedBox(height: AppSpace.xs),
        // The equation, as a line rather than as something the reader works out.
        // When it does not hold the difference is printed too, because "does not
        // balance" without a figure is a shrug.
        DocumentPair(
          label: difference == Decimal.zero
              ? 'Total assets = liabilities + equity'
              : 'Out by',
          value: _plain(difference.abs()),
          emphasis: true,
          colorize: true,
          negative: difference != Decimal.zero,
        ),
      ],
    ),
  );
}

/// (groupTitle, (accountName, amount)) for one section of the sheet.
List<(String, (String, Decimal))> _sectionFor(
  ReportResult result,
  String section,
  ReportColumn amount,
) => [
  for (final row in result.rows)
    if (row.cells['section'] == section)
      (
        '${row.cells['group'] ?? ''}',
        ('${row.cells['account'] ?? ''}', row.number(amount)),
      ),
];

Decimal _totalOf(List<(String, (String, Decimal))> lines) =>
    lines.fold(Decimal.zero, (sum, line) => sum + line.$2.$2);

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.groups,
    required this.total,
    required this.amount,
  });

  final String title;
  final List<(String, (String, Decimal))> groups;
  final Decimal total;
  final ReportColumn amount;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) return const SizedBox.shrink();
    // The group headings come from the source, in source order, with a heading
    // drawn wherever the title changes — so a source that adds a group needs no
    // change here and cannot produce two headings for one group.
    final blocks = <Widget>[];
    String? current;
    for (final (group, (account, value)) in groups) {
      if (group != current) {
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs, bottom: 2),
            child: Text(
              group,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
        current = group;
      }
      blocks.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  account,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              MoneyText(
                value,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.right,
              ),
            ],
          ),
        ),
      );
    }
    return DocumentSection(
      title: '$title — ${_plain(total)}',
      children: blocks,
    );
  }
}

String _plain(Decimal value) => value.round(scale: 2).toStringAsFixed(2);
