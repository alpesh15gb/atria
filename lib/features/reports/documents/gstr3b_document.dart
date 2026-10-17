import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/theme/app_sizes.dart';
import 'package:atria/shared/widgets/common_widgets.dart';
import 'package:atria/shared/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

/// **GSTR-3B** — the monthly summary return, grouped by the portal's sections:
/// 3.1 (Outward & Reverse Charge), 3.2 (Inter-state unregistered breakdown),
/// 4 (Eligible ITC), and 5 (Exempt / Non-GST inward supplies).
Widget? buildGstr3b(BuildContext context, ReportResult result) {
  if (result.rows.isEmpty) return null;

  final taxableCol = result.spec.columns.firstWhere((c) => c.key == 'taxable');
  final igstCol = result.spec.columns.firstWhere((c) => c.key == 'igst');
  final cgstCol = result.spec.columns.firstWhere((c) => c.key == 'cgst');
  final sgstCol = result.spec.columns.firstWhere((c) => c.key == 'sgst');
  final cessCol = result.spec.columns.firstWhere((c) => c.key == 'cess');
  final itcCol = result.spec.columns.firstWhere((c) => c.key == 'itc');
  final totalCol = result.spec.columns.firstWhere((c) => c.key == 'total');

  final section31 = <ReportRow>[];
  final section32 = <ReportRow>[];
  final section4 = <ReportRow>[];
  final section5 = <ReportRow>[];

  for (final row in result.rows) {
    final table = '${row.cells['table'] ?? ''}';
    if (table.startsWith('3.1')) {
      section31.add(row);
    } else if (table == '3.2') {
      section32.add(row);
    } else if (table.startsWith('4') || table == 'Net ITC') {
      section4.add(row);
    } else if (table == '5') {
      section5.add(row);
    }
  }

  Decimal outputLiability = Decimal.zero;
  for (final row in section31) {
    outputLiability += row.number(totalCol);
  }
  Decimal netItc = Decimal.zero;
  for (final row in section4) {
    if ('${row.cells['table']}' == 'Net ITC') {
      netItc = row.number(itcCol);
    }
  }
  final payableRows = result.rows.where((row) => row.cells['table'] == 'Net payable');
  final netPayable = payableRows.isEmpty ? outputLiability - netItc
      : payableRows.single.number(totalCol);

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
        _Gstr3bSummaryCard(
          outputLiability: outputLiability,
          netItc: netItc,
          netPayable: netPayable,
        ),
        const SizedBox(height: AppSpace.sm),
        if (section31.isNotEmpty)
          _Gstr3bSectionCard(
            title:
                '3.1 Details of Outward Supplies and Inward Supplies Liable to Reverse Charge',
            rows: section31,
            taxableCol: taxableCol,
            igstCol: igstCol,
            cgstCol: cgstCol,
            sgstCol: sgstCol,
            cessCol: cessCol,
            itcCol: itcCol,
            totalCol: totalCol,
            mode: _Gstr3bSectionMode.outward,
          ),
        if (section32.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          _Gstr3bSectionCard(
            title: '3.2 Inter-State Supplies to Unregistered Persons',
            rows: section32,
            taxableCol: taxableCol,
            igstCol: igstCol,
            cgstCol: cgstCol,
            sgstCol: sgstCol,
            cessCol: cessCol,
            itcCol: itcCol,
            totalCol: totalCol,
            mode: _Gstr3bSectionMode.outward,
          ),
        ],
        if (section4.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          _Gstr3bSectionCard(
            title: '4. Eligible ITC (Input Tax Credit)',
            rows: section4,
            taxableCol: taxableCol,
            igstCol: igstCol,
            cgstCol: cgstCol,
            sgstCol: sgstCol,
            cessCol: cessCol,
            itcCol: itcCol,
            totalCol: totalCol,
            mode: _Gstr3bSectionMode.itc,
          ),
        ],
        if (section5.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          _Gstr3bSectionCard(
            title: '5. Values of Exempt, Nil-Rated and Non-GST Inward Supplies',
            rows: section5,
            taxableCol: taxableCol,
            igstCol: igstCol,
            cgstCol: cgstCol,
            sgstCol: sgstCol,
            cessCol: cessCol,
            itcCol: itcCol,
            totalCol: totalCol,
            mode: _Gstr3bSectionMode.exemptInward,
          ),
        ],
      ],
    ),
  );
}

enum _Gstr3bSectionMode { outward, itc, exemptInward }

class _Gstr3bSummaryCard extends StatelessWidget {
  const _Gstr3bSummaryCard({
    required this.outputLiability,
    required this.netItc,
    required this.netPayable,
  });

  final Decimal outputLiability;
  final Decimal netItc;
  final Decimal netPayable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isCreditSurplus = netPayable < Decimal.zero;
    return AtriaCard(
      padding: const EdgeInsets.all(14),
      background: scheme.primaryContainer.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'GSTR-3B Monthly Liability Summary',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _SummaryItem(
                  label: 'Output Tax (3.1)',
                  amount: outputLiability,
                ),
              ),
              Expanded(
                child: _SummaryItem(
                  label: 'Eligible Net ITC (4)',
                  amount: netItc,
                ),
              ),
              Expanded(
                child: _SummaryItem(
                  label: isCreditSurplus ? 'ITC Carryover' : 'Net Tax Payable',
                  amount: isCreditSurplus ? -netPayable : netPayable,
                  alignRight: true,
                  emphasise: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({
    required this.label,
    required this.amount,
    this.alignRight = false,
    this.emphasise = false,
  });

  final String label;
  final Decimal amount;
  final bool alignRight;
  final bool emphasise;

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
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: emphasise ? FontWeight.w800 : FontWeight.w700,
            color: emphasise ? scheme.primary : scheme.onSurface,
          ),
        ),
      ],
    );
  }
}

class _Gstr3bSectionCard extends StatelessWidget {
  const _Gstr3bSectionCard({
    required this.title,
    required this.rows,
    required this.taxableCol,
    required this.igstCol,
    required this.cgstCol,
    required this.sgstCol,
    required this.cessCol,
    required this.itcCol,
    required this.totalCol,
    required this.mode,
  });

  final String title;
  final List<ReportRow> rows;
  final ReportColumn taxableCol;
  final ReportColumn igstCol;
  final ReportColumn cgstCol;
  final ReportColumn sgstCol;
  final ReportColumn cessCol;
  final ReportColumn itcCol;
  final ReportColumn totalCol;
  final _Gstr3bSectionMode mode;

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
    final isNetItc = table == 'Net ITC';

    final taxable = row.number(taxableCol);
    final igst = row.number(igstCol);
    final cgst = row.number(cgstCol);
    final sgst = row.number(sgstCol);
    final cess = row.number(cessCol);
    final itc = row.number(itcCol);
    final total = row.number(totalCol);

    return Container(
      padding: const EdgeInsets.all(12),
      color: isNetItc
          ? scheme.primaryContainer.withValues(alpha: 0.45)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: isNetItc
                      ? scheme.primary
                      : scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  table,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isNetItc
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
                    fontWeight: isNetItc ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (mode == _Gstr3bSectionMode.itc)
                MoneyText(
                  itc,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: isNetItc ? FontWeight.w700 : FontWeight.w600,
                  ),
                )
              else if (mode == _Gstr3bSectionMode.exemptInward)
                MoneyText(
                  taxable,
                  colorize: false,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          if (mode == _Gstr3bSectionMode.outward) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              alignment: WrapAlignment.spaceBetween,
              children: [
                _SubFigure(label: 'Taxable', amount: taxable, bold: true),
                _SubFigure(label: 'IGST', amount: igst),
                _SubFigure(label: 'CGST', amount: cgst),
                _SubFigure(label: 'SGST', amount: sgst),
                if (cess > Decimal.zero) _SubFigure(label: 'Cess', amount: cess),
                _SubFigure(label: 'Total tax', amount: total, bold: true),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SubFigure extends StatelessWidget {
  const _SubFigure({
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
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
