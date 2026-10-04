import 'package:flutter/material.dart';

import '../../core/reports/engine/report_result.dart';
import '../../core/reports/spec/report_spec.dart';

/// A bespoke report's own anatomy, sitting under the same toolbar and export.
///
/// Nine reports do not fit a grid: P&L, Trial Balance, Balance Sheet, Cash flow,
/// GSTR-1/3B/9, Stock Detail, Day book. Each has a shape — a debit/credit
/// column pair, a return's table numbering, a signed opening/closing pair —
/// and forcing them into `ReportDataTable` would mean expressing a trial balance
/// as "Description | Debit | Credit", which is legible but is a lie about what
/// the thing is.
///
/// **What this buys is that they still get everything else.** The window
/// toolbar, the export button, the filters, the integrity banner and the empty
/// state all come from [ReportViewPage]; this widget only replaces the body.
/// A P&L that a CA cannot export is a P&L they retype.
///
/// Each implementation is a widget over a [ReportResult] rather than a private
/// class inside a screen, so it is unit-testable without pumping a widget tree —
/// the same reason the private `_Card` classes in `reports_screen.dart` are
/// being lifted out rather than copied.
class ReportDocumentView extends StatelessWidget {
  const ReportDocumentView({
    super.key,
    required this.result,
    required this.builder,
  });

  final ReportResult result;

  /// The bespoke body. Returns null when it has nothing to draw, and the
  /// fallback table renders instead — a document report with no rows is empty,
  /// not broken, and must not render a blank screen that looks like a crash.
  final Widget? Function(BuildContext, ReportResult) builder;

  @override
  Widget build(BuildContext context) {
    final body = builder(context, result);
    if (body != null) return body;
    return _ColumnFallback(result: result);
  }
}

/// The generic table for a document-layout report.
///
/// A document report still declares columns — deliberately, so its export is
/// the same rows it shows (see [ReportSpec.layout]). When a bespoke builder
/// has nothing to draw, those columns are better than nothing.
class _ColumnFallback extends StatelessWidget {
  const _ColumnFallback({required this.result});

  final ReportResult result;

  @override
  Widget build(BuildContext context) {
    final spec = result.spec;
    final scheme = Theme.of(context).colorScheme;
    if (spec.columns.isEmpty) {
      return Center(
        child: Text(
          'Nothing to show for ${result.window.spanLabel}.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < spec.columns.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 180,
                    child: Text(
                      spec.columns[i].label,
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      result.rows.isEmpty
                          ? '—'
                          : (result.rows.first.text(spec.columns[i])),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A labelled pair of figures, the unit every one of the nine documents is
/// built from — an opening balance, a closing balance, a taxable value.
///
/// **[emphasis] is what makes a total read as a total** rather than as one more
/// line: the difference between "there is a number here" and "this is the
/// number" is weight, not size.
class DocumentPair extends StatelessWidget {
  const DocumentPair({
    super.key,
    required this.label,
    required this.value,
    this.emphasis = false,
    this.colorize = false,
    this.negative = false,
  });

  final String label;
  final String value;

  /// Draws this line as a total: bold, on a filled band.
  final bool emphasis;

  /// Renders [value] in the error colour when [negative] is true.
  final bool colorize;
  final bool negative;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = emphasis
        ? Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            )
        : Theme.of(context).textTheme.bodyMedium;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: emphasis
          ? BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: emphasis
                  ? style
                  : Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: style?.copyWith(
              color: colorize && negative ? scheme.error : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// A section heading inside a document — "Income", "Expenses", "Table 12".
class DocumentSection extends StatelessWidget {
  const DocumentSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
        ),
        const Divider(height: 8),
        ...children,
      ],
    );
  }
}