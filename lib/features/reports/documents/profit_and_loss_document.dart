import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/theme/app_sizes.dart';
import 'package:atria/shared/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../report_document_view.dart';

/// **Profit And Loss**, drawn as the statement rather than as a grid.
///
/// The reason this is not `ReportDataTable`: a P&L has an *order and a rule*.
/// Income, a ruled total, expenses, a ruled total, gross profit, net — and a
/// flat "Description | Amount" table cannot express the rule between the
/// sections, so the one line a CA reads first is not on the page.
///
/// Every figure comes from `result.rows`, which is the same list the export
/// writes. **That is the whole constraint**: the screen and the CSV are two
/// renderings of one source, so a P&L that looks right on screen and wrong in
/// the file handed to the CA cannot happen.
Widget? buildProfitAndLoss(BuildContext context, ReportResult result) {
  final income = _linesFor(result, 'Income');
  final expense = _linesFor(result, 'Expense');
  final stock = _linesFor(result, 'Stock');

  if (income.isEmpty && expense.isEmpty && stock.isEmpty) return null;

  final totalIncome = _totalFor(result, 'Total income');
  final totalExpenses = _totalFor(result, 'Total expenses');
  // Gross and net are **read from the source's own rows**, not derived here.
  //
  // They used to be derived as one figure (`totalIncome - totalExpenses`) and
  // then printed twice, under two different names — so the statement showed
  // "Gross profit" and "Net profit" as the identical number and a CA could not
  // tell which was which. They are genuinely different: gross is sales less
  // cost of goods sold, net additionally absorbs other income and operating
  // expenses. `ProfitAndLoss` computes both.
  final grossProfit = _totalFor(result, 'Gross profit');
  final netProfit = _totalFor(result, 'Net profit');

  return SingleChildScrollView(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpace.sm,
      vertical: AppSpace.xs,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (income.isNotEmpty) ...[
          DocumentSection(
            title: 'Income',
            children: [
              for (final line in income) _Line(label: line.$1, amount: line.$2),
              const Divider(height: 1),
              DocumentPair(
                label: 'Total income',
                value: _plain(totalIncome),
                emphasis: true,
              ),
            ],
          ),
        ],
        if (expense.isNotEmpty) ...[
          DocumentSection(
            title: 'Expenses',
            children: [
              for (final line in expense)
                _Line(label: line.$1, amount: line.$2),
              const Divider(height: 1),
              DocumentPair(
                label: 'Total expenses',
                value: _plain(totalExpenses),
                emphasis: true,
                colorize: true,
                negative: totalExpenses < Decimal.zero,
              ),
            ],
          ),
        ],
        if (stock.isNotEmpty)
          DocumentSection(
            title: 'Stock',
            children: [
              for (final line in stock) _Line(label: line.$1, amount: line.$2),
            ],
          ),
        if (income.isNotEmpty || expense.isNotEmpty) ...[
          const SizedBox(height: AppSpace.xs),
          DocumentPair(
            label: 'Gross profit',
            value: _plain(grossProfit),
            emphasis: true,
            colorize: true,
            negative: grossProfit < Decimal.zero,
          ),
          DocumentPair(
            label: 'Net profit',
            value: _plain(netProfit),
            emphasis: true,
            colorize: true,
            negative: netProfit < Decimal.zero,
          ),
        ],
      ],
    ),
  );
}

/// Every row of one section, as (label, amount).
///
/// Sections are read from the source's own `section` cell rather than from
/// position, so a line added to the P&L source appears here without this file
/// knowing anything about it.
List<(String, Decimal)> _linesFor(ReportResult result, String section) {
  final column = result.spec.columns.firstWhere((c) => c.key == 'amount');
  return [
    for (final row in result.rows)
      if (row.cells['section'] == section)
        ('${row.cells['label']}', row.number(column)),
  ];
}

/// The source's own total line, or nil when it did not draw one.
Decimal _totalFor(ReportResult result, String label) {
  final column = result.spec.columns.firstWhere((c) => c.key == 'amount');
  for (final row in result.rows) {
    if (row.cells['label'] == label) return row.number(column);
  }
  return Decimal.zero;
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.amount});

  final String label;
  final Decimal amount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(width: 12),
          MoneyText(
            amount,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.right,
          ),
        ],
      ),
    );
  }
}

String _plain(Decimal value) => value.round(scale: 2).toStringAsFixed(2);
