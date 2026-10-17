import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/theme/app_sizes.dart';
import 'package:atria/shared/widgets/common_widgets.dart';
import 'package:atria/shared/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

/// **GSTR-1** — the outward supplies return drawn in the shape of the portal's
/// table summaries (Tables 4A/4B, 6B/6C, 7, 13A, 13B, 9B/9A, 10).
///
/// Every figure comes from [result.rows] produced by [gstr1Rows]. Returns null
/// when there are no rows (e.g., an unregistered firm), letting
/// [ReportDocumentView] render the empty state.
Widget? buildGstr1(BuildContext context, ReportResult result) {
  if (result.rows.isEmpty) return null;

  final taxableCol = result.spec.columns.firstWhere((c) => c.key == 'taxable');
  final cgstCol = result.spec.columns.firstWhere((c) => c.key == 'cgst');
  final sgstCol = result.spec.columns.firstWhere((c) => c.key == 'sgst');
  final igstCol = result.spec.columns.firstWhere((c) => c.key == 'igst');
  final cessCol = result.spec.columns.firstWhere((c) => c.key == 'cess');
  final totalCol = result.spec.columns.firstWhere((c) => c.key == 'total');

  final outwardRows = <ReportRow>[];
  final exportRows = <ReportRow>[];
  final noteRows = <ReportRow>[];

  for (final row in result.rows) {
    final table = '${row.cells['table'] ?? ''}';
    if (table.startsWith('13')) {
      exportRows.add(row);
    } else if (table.startsWith('9') || table == '10') {
      noteRows.add(row);
    } else {
      outwardRows.add(row);
    }
  }

  Decimal netTaxable = Decimal.zero;
  Decimal netTax = Decimal.zero;
  for (final row in outwardRows) {
    netTaxable += row.number(taxableCol);
    netTax += row.number(totalCol);
  }
  for (final row in exportRows) {
    netTaxable += row.number(taxableCol);
    netTax += row.number(totalCol);
  }
  for (final row in noteRows) {
    netTaxable -= row.number(taxableCol);
    netTax -= row.number(totalCol);
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
        _ReturnSummaryBanner(
          title: 'GSTR-1 Outward Supplies Summary',
          leftLabel: 'Net Taxable Value',
          leftAmount: netTaxable,
          rightLabel: 'Net Output Tax',
          rightAmount: netTax,
        ),
        const SizedBox(height: AppSpace.sm),
        if (outwardRows.isNotEmpty) ...[
          _SectionHeader(title: 'Domestic Outward Supplies (Tables 4, 6 & 7)'),
          const SizedBox(height: AppSpace.xxs),
          for (final row in outwardRows)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: _Gstr1TableCard(
                row: row,
                taxableCol: taxableCol,
                cgstCol: cgstCol,
                sgstCol: sgstCol,
                igstCol: igstCol,
                cessCol: cessCol,
                totalCol: totalCol,
              ),
            ),
        ],
        if (exportRows.isNotEmpty) ...[
          const SizedBox(height: AppSpace.xs),
          _SectionHeader(title: 'Zero-Rated Exports (Tables 13A & 13B)'),
          const SizedBox(height: AppSpace.xxs),
          for (final row in exportRows)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: _Gstr1TableCard(
                row: row,
                taxableCol: taxableCol,
                cgstCol: cgstCol,
                sgstCol: sgstCol,
                igstCol: igstCol,
                cessCol: cessCol,
                totalCol: totalCol,
              ),
            ),
        ],
        if (noteRows.isNotEmpty) ...[
          const SizedBox(height: AppSpace.xs),
          _SectionHeader(title: 'Credit / Debit Notes (Tables 9B & 10)'),
          const SizedBox(height: AppSpace.xxs),
          for (final row in noteRows)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: _Gstr1TableCard(
                row: row,
                taxableCol: taxableCol,
                cgstCol: cgstCol,
                sgstCol: sgstCol,
                igstCol: igstCol,
                cessCol: cessCol,
                totalCol: totalCol,
                isReduction: true,
              ),
            ),
        ],
      ],
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ReturnSummaryBanner extends StatelessWidget {
  const _ReturnSummaryBanner({
    required this.title,
    required this.leftLabel,
    required this.leftAmount,
    required this.rightLabel,
    required this.rightAmount,
  });

  final String title;
  final String leftLabel;
  final Decimal leftAmount;
  final String rightLabel;
  final Decimal rightAmount;

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
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _MetricTile(label: leftLabel, amount: leftAmount),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _MetricTile(
                  label: rightLabel,
                  amount: rightAmount,
                  alignRight: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.amount,
    this.alignRight = false,
  });

  final String label;
  final Decimal amount;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: alignRight
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        MoneyText(
          amount,
          colorize: false,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _Gstr1TableCard extends StatelessWidget {
  const _Gstr1TableCard({
    required this.row,
    required this.taxableCol,
    required this.cgstCol,
    required this.sgstCol,
    required this.igstCol,
    required this.cessCol,
    required this.totalCol,
    this.isReduction = false,
  });

  final ReportRow row;
  final ReportColumn taxableCol;
  final ReportColumn cgstCol;
  final ReportColumn sgstCol;
  final ReportColumn igstCol;
  final ReportColumn cessCol;
  final ReportColumn totalCol;
  final bool isReduction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final table = '${row.cells['table'] ?? ''}';
    final description = '${row.cells['description'] ?? ''}';
    final rawCount = row.cells['count'];
    final countText = rawCount is Decimal
        ? rawCount.toBigInt().toString()
        : '${rawCount ?? '—'}';

    final taxable = row.number(taxableCol);
    final cgst = row.number(cgstCol);
    final sgst = row.number(sgstCol);
    final igst = row.number(igstCol);
    final cess = row.number(cessCol);
    final total = row.number(totalCol);

    return AtriaCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Table $table',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  description,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                countText == '—' ? 'Aggregated' : '$countText docs',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const Divider(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              _HeadCell(label: 'Taxable value', amount: taxable, bold: true),
              _HeadCell(label: 'IGST', amount: igst),
              _HeadCell(label: 'CGST', amount: cgst),
              _HeadCell(label: 'SGST', amount: sgst),
              if (cess > Decimal.zero) _HeadCell(label: 'Cess', amount: cess),
              _HeadCell(
                label: isReduction ? 'Tax reduced' : 'Tax charged',
                amount: total,
                bold: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeadCell extends StatelessWidget {
  const _HeadCell({
    required this.label,
    required this.amount,
    this.bold = false,
  });

  final String label;
  final Decimal amount;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        MoneyText(
          amount,
          colorize: false,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
