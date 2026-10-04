import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/reports/engine/report_result.dart';
import '../../core/reports/spec/report_spec.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/theme/app_typography.dart';

/// A report's rows, rendered two ways from one list.
///
/// **Wide** gets a real table: a header that stays put while the rows scroll, a
/// right-aligned money column with tabular figures, a subtotal under each
/// group, and a grand total pinned to the bottom.
///
/// **Narrow** gets cards, and the `wideOnly` columns drop out — a stock report's
/// unit column is redundant once the row already says what the item is.
///
/// Why not `AtriaLineGrid`, which every other list in the app uses? Because
/// that widget owns an editable-cell model — selection ranges, in-place editing,
/// keyboard navigation — and a read-only report has no use for any of it.
/// Borrowing it would mean 46 report screens paying for a data model they
/// cannot act on.
class ReportDataTable extends StatelessWidget {
  const ReportDataTable({
    super.key,
    required this.result,
    required this.columns,
  });

  final ReportResult result;

  /// The columns to show. The caller has already dropped `wideOnly` ones on a
  /// narrow screen, so this is [ReportSpec.narrowColumns] there and the full
  /// list here.
  final List<ReportColumn> columns;

  /// Digits that line up vertically.
  ///
  /// Without this, `1,111.00` and `88.50` render with different digit widths and
  /// a column of money is a staircase. It is the same reason a spreadsheet uses
  /// tabular figures, and the reason a reader can find the total by looking down
  /// the column rather than reading every row.
  static const List<FontFeature> _tabular = [
    FontFeature.tabularFigures(),
  ];

  @override
  Widget build(BuildContext context) {
    if (columns.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        // The table needs roughly 90dp per column before it stops being
        // readable; below that the cards are the better answer, and they are
        // the answer a phone gets regardless.
        final wide = constraints.maxWidth >= columns.length * 90.0;
        return wide ? _wideTable(context) : _cardList(context);
      },
    );
  }

  // ---- Wide ---------------------------------------------------------------

  Widget _wideTable(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Sticky header + a pinned total means the table is two slivers, not a
    // scrolling Column: putting the total in the flow would scroll it off the
    // bottom of a 400-row report, which is the one row that must always be
    // visible.
    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: _HeaderDelegate(
                  background: isDark
                      ? scheme.surfaceContainerHighest
                      : AppColors.surfaceVariant,
                  child: _headerRow(context),
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _sliverChild(context, index),
                  // The rows are already built; adding an index-based cache
                  // would only hide the rebuild when a filter changes.
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: true,
                  childCount: _rowCount(),
                ),
              ),
            ],
          ),
        ),
        _grandTotalBar(context),
      ],
    );
  }

  /// Every printable line: a group's rows, its subtotal, the next group.
  List<_Line> _lines() {
    final out = <_Line>[];
    final spec = result.spec;
    for (final group in result.groups) {
      if (spec.isGrouped) {
        out.add(_Heading(group.name, group.label));
      }
      for (final row in group.rows) {
        out.add(_Data(row));
      }
      if (spec.isGrouped) {
        out.add(_Subtotal(spec.groupBy.totalLabel, group));
      }
    }
    return out;
  }

  int _rowCount() => _lines().length;

  Widget _sliverChild(BuildContext context, int index) {
    final line = _lines()[index];
    return switch (line) {
      _Heading(:final name, :final label) =>
        _groupHeading(context, name, label),
      _Subtotal(:final label, :final group) =>
        _subtotalRow(context, label, group),
      _Data(:final row) => _dataRow(context, row),
    };
  }

  Widget _headerRow(BuildContext context) {
    return Row(
      children: [
        for (final column in columns) ...[
          Expanded(
            flex: column.flex,
            child: _cell(context, column.label, column, header: true),
          ),
          const SizedBox(width: AppSpace.xs),
        ],
      ],
    );
  }

  Widget _groupHeading(BuildContext context, String name, String? label) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        vertical: AppSpace.xs,
        horizontal: AppSpace.sm,
      ),
      color: isDark
          ? scheme.surfaceContainerHighest
          : AppColors.primarySurface,
      child: Text(
        label == null ? name : '$name  ·  $label',
        style: AppTypography.textTheme.labelLarge?.copyWith(
          color: isDark ? scheme.onSurface : AppColors.primaryDeep,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _dataRow(BuildContext context, ReportRow row) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      // A hairline rather than a full border: at 46 reports × 8 columns a
      // bordered cell is a grid nobody can read figures out of.
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
      child: Row(
        children: [
          for (final column in columns) ...[
            Expanded(flex: column.flex, child: _cell(context, row.text(column), column, row: row)),
            const SizedBox(width: AppSpace.xs),
          ],
        ],
      ),
    );
  }

  Widget _subtotalRow(BuildContext context, String label, ReportGroup group) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      decoration: BoxDecoration(
        color: isDark
            ? scheme.surfaceContainerHighest
            : AppColors.surfaceHigh,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: 0.5),
          bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          for (final column in columns) ...[
            Expanded(
              flex: column.flex,
              child: column.isSummable
                  ? _cell(
                      context,
                      // `exportNumber` rather than `text`: a subtotal is a
                      // figure someone will add up, and the display formatter
                      // rounds for looks. Both are 2dp; this one is explicit.
                      ReportRow.exportNumber(group.totalFor(column)),
                      column,
                      bold: true,
                    )
                  : _cell(
                      context,
                      column == columns.first ? label : '',
                      column,
                      bold: true,
                    ),
            ),
            const SizedBox(width: AppSpace.xs),
          ],
        ],
      ),
    );
  }

  /// The grand total, always on screen.
  ///
  /// Pinned rather than appended: on a 400-row report the last line is 40
  /// scrolls away, and the total is the one line a reader came for.
  Widget _grandTotalBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpace.xs,
        horizontal: AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        border: Border(top: BorderSide(color: scheme.primary, width: 1)),
      ),
      child: Row(
        children: [
          for (final column in columns) ...[
            Expanded(
              flex: column.flex,
              child: column.isSummable
                  ? _cell(
                      context,
                      ReportRow.exportNumber(result.grandTotalFor(column)),
                      column,
                      bold: true,
                    )
                  : _cell(
                      context,
                      column == columns.first ? 'Total' : '',
                      column,
                      bold: true,
                    ),
            ),
            const SizedBox(width: AppSpace.xs),
          ],
        ],
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    String text,
    ReportColumn column, {
    bool header = false,
    bool bold = false,
    ReportRow? row,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final base = header
        ? AppTypography.textTheme.labelMedium
        : AppTypography.textTheme.bodySmall;
    var color = header ? scheme.onSurfaceVariant : scheme.onSurface;
    if (bold) color = scheme.onPrimaryContainer;
    if (!header && row != null && column.colorize) {
      final value = row.number(column);
      if (value < Decimal.zero) color = scheme.error;
    }
    final isNumeric = column.effectiveAlign == ReportColumnAlign.right;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xxs),
      child: Text(
        text,
        textAlign: switch (column.effectiveAlign) {
          ReportColumnAlign.left => TextAlign.left,
          ReportColumnAlign.right => TextAlign.right,
          ReportColumnAlign.center => TextAlign.center,
          ReportColumnAlign.auto => TextAlign.left,
        },
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: base?.copyWith(
          color: color,
          fontWeight: bold || column.emphasise
              ? FontWeight.w600
              : FontWeight.w400,
          // Tabular figures on the numeric columns only. Applying it to text
          // would give a party name a monospaced look for no reason.
          fontFeatures: isNumeric ? _tabular : null,
        ),
      ),
    );
  }

  // ---- Narrow -------------------------------------------------------------

  Widget _cardList(BuildContext context) {
    final lines = _lines();
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpace.sm),
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        return switch (line) {
          _Heading(:final name, :final label) =>
            _cardHeading(context, name, label),
          _Subtotal(:final label, :final group) =>
            _cardSubtotal(context, label, group),
          _Data(:final row) => _dataCard(context, row),
        };
      },
    );
  }

  Widget _cardHeading(BuildContext context, String name, String? label) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.xs, AppSpace.sm, AppSpace.xs, AppSpace.xxs),
      child: Text(
        label == null ? name : '$name  ·  $label',
        style: AppTypography.textTheme.labelLarge
            ?.copyWith(color: scheme.primary),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// One row as a card: the emphasised figure on top, the rest beneath.
  Widget _dataCard(BuildContext context, ReportRow row) {
    final scheme = Theme.of(context).colorScheme;
    final lead = columns.firstWhere(
      (c) => c.emphasise,
      orElse: () => columns.first,
    );
    final rest = columns.where((c) => c != lead).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xs),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.sm),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: scheme.outlineVariant, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              row.text(lead),
              style: AppTypography.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpace.xxs),
            // Label: value pairs, because a bare column of figures with the
            // headings three screens up is unreadable on a phone.
            for (final column in rest)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.xxs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(
                        column.label,
                        style: AppTypography.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        row.text(column),
                        textAlign: TextAlign.right,
                        style: AppTypography.textTheme.bodySmall?.copyWith(
                          fontWeight: column.kind == ReportValueKind.money
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: _cardValueColor(row, column, scheme),
                          fontFeatures: column.kind == ReportValueKind.money
                              ? _tabular
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _cardSubtotal(BuildContext context, String label, ReportGroup group) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xs, left: AppSpace.sm),
      child: Row(
        children: [
          Text(
            label,
            style: AppTypography.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const Spacer(),
          for (final column in columns.where((c) => c.isSummable))
            Text(
              ReportRow.exportNumber(group.totalFor(column)),
              style: AppTypography.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: _tabular,
              ),
            ),
        ],
      ),
    );
  }

  Color _cardValueColor(ReportRow row, ReportColumn column, ColorScheme scheme) {
    if (!column.colorize) return scheme.onSurface;
    return row.number(column) < Decimal.zero ? scheme.error : scheme.onSurface;
  }
}

/// One printed line, flattened.
///
/// The wide table and the card list render the *same* lines through different
/// widgets, so the two cannot drift: a subtotal that appears in one appears in
/// the other, in the same place, because there is only one list of them.
sealed class _Line {
  const _Line();
}

class _Heading extends _Line {
  const _Heading(this.name, this.label);
  final String name;
  final String? label;
}

class _Data extends _Line {
  const _Data(this.row);
  final ReportRow row;
}

class _Subtotal extends _Line {
  const _Subtotal(this.label, this.group);
  final String label;
  final ReportGroup group;
}

/// The pinned header row.
class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  const _HeaderDelegate({
    required this.child,
    required this.background,
  });

  final Widget child;
  final Color background;

  @override
  double get minExtent => 34;

  @override
  double get maxExtent => 34;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      alignment: Alignment.centerLeft,
      child: child,
    );
  }

  @override
  bool shouldRebuild(_HeaderDelegate old) =>
      old.background != background || old.child != child;
}