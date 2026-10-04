import 'dart:math';

import 'package:decimal/decimal.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/repositories/report_repository.dart';
import '../../core/engine/document_numbering.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atria_nav_row.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';

// ---------------------------------------------------------------------------
// Reporting period
// ---------------------------------------------------------------------------

enum _Period { thisMonth, thisQuarter, thisFY, custom }

class _DateRange {
  const _DateRange(this.from, this.to);

  final DateTime from;
  final DateTime to;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _DateRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  String get label => '${Formatters.date(from)}  –  ${Formatters.date(to)}';
}

/// Picks a "nice" axis step (1, 2 or 5 × 10ⁿ) so the chart's horizontal grid
/// lines land on round numbers of rupees.
double _niceInterval(double maxValue) {
  if (maxValue <= 0) return 1;
  final raw = maxValue / 4;
  final magnitude = pow(10, (log(raw) / ln10).floor()).toDouble();
  final normalized = raw / magnitude;
  final step = normalized >= 5
      ? 5.0
      : normalized >= 2
      ? 2.0
      : 1.0;
  return step * magnitude;
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  _Period _period = _Period.thisMonth;
  DateTime _customFrom = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _customTo = DateTime.now();
  DateTime _dayBookDay = DateTime.now();

  /// The window every period-scoped report is computed over.
  _DateRange get _range {
    final now = DateTime.now();
    switch (_period) {
      case _Period.thisMonth:
        return _DateRange(
          DateTime(now.year, now.month, 1),
          DateTime(now.year, now.month, now.day, 23, 59, 59),
        );
      case _Period.thisQuarter:
        // Quarters follow the Indian financial year: Apr–Jun, Jul–Sep, …
        final fy = FinancialYear.current();
        final elapsed =
            (now.year - fy.start.year) * 12 + now.month - fy.start.month;
        final quarter = elapsed.clamp(0, 11) ~/ 3;
        final start = DateTime(fy.start.year, fy.start.month + quarter * 3, 1);
        // The end is the quarter's ACTUAL last day at 23:59:59, never
        // `DateTime.now()`. For the ~three quarters of the year that are
        // still in progress, `now` advanced a few milliseconds on every
        // rebuild, so `_DateRange` — which has value equality on from/to —
        // compared unequal each time and every card's `didUpdateWidget`
        // re-issued its queries: changing the day-book date, resizing the
        // window or any ancestor rebuild re-ran the whole books from scratch.
        // A quarter that has not ended yet cannot contain rows dated after its
        // last day, so querying to the quarter end returns exactly the same
        // rows while comparing equal every time.
        final end = DateTime(
          fy.start.year,
          fy.start.month + quarter * 3 + 3,
          0,
          23,
          59,
          59,
        );
        return _DateRange(start, end);
      case _Period.thisFY:
        final fy = FinancialYear.current();
        return _DateRange(fy.start, fy.end);
      case _Period.custom:
        final from = _customFrom.isBefore(_customTo) ? _customFrom : _customTo;
        final later = _customFrom.isBefore(_customTo) ? _customTo : _customFrom;
        return _DateRange(
          from,
          DateTime(later.year, later.month, later.day, 23, 59, 59),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(reportRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (repo == null) {
              return const EmptyState(
                icon: Icons.storefront_outlined,
                title: 'No business open',
                message:
                    'Set up a firm in Settings to generate GST, '
                    'profit-and-loss and day-book reports.',
              );
            }

            final range = _range;
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _reportLibrary()),
                SliverToBoxAdapter(child: _periodSelector(range)),
                SliverToBoxAdapter(
                  child: _pad(
                    SectionHeader(
                      title: 'Goods & Services Tax',
                      subtitle:
                          'Output tax, input credit and rate-wise '
                          'outward supplies · ${range.label}',
                      padding: const EdgeInsets.fromLTRB(4, 14, 4, 10),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: _pad(_GstCard(repo: repo, range: range)),
                ),
                SliverToBoxAdapter(
                  child: _pad(
                    SectionHeader(
                      title: 'Tax at source',
                      subtitle:
                          'Deducted on purchases and collected on sales '
                          '· ${range.label}',
                      padding: const EdgeInsets.fromLTRB(4, 14, 4, 10),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: _pad(_TaxAtSourceCard(repo: repo, range: range)),
                ),
                SliverToBoxAdapter(
                  child: _pad(
                    SectionHeader(
                      title: 'Sales vs Purchases',
                      subtitle: 'Monthly trading trend',
                      padding: const EdgeInsets.fromLTRB(4, 14, 4, 10),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: _pad(_TrendCard(repo: repo))),
                SliverToBoxAdapter(
                  child: _pad(
                    SectionHeader(
                      title: 'Statements',
                      subtitle: 'Profit & loss, day book, balances and stock',
                      padding: const EdgeInsets.fromLTRB(4, 14, 4, 10),
                    ),
                  ),
                ),
                ..._statementGrid(repo, constraints, range),
                const SliverToBoxAdapter(child: SizedBox(height: 96)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _pad(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: child,
  );

  // ---- Report library ----------------------------------------------------

  /// The destinations that used to hide behind app-bar icons. Every reference
  /// app leads its reports screen with a labelled list of report families
  /// rather than icon-only actions, so the same rows sit above the filters
  /// here.
  Widget _reportLibrary() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pad(
          const SectionHeader(
            title: 'Report library',
            subtitle: 'Returns, stock and party statements',
            padding: EdgeInsets.fromLTRB(4, 14, 4, 10),
          ),
        ),
        _pad(
          AtriaNavRowList(
            children: [
              AtriaNavRow(
                icon: Icons.fact_check_outlined,
                title: 'GST returns',
                subtitle:
                    'GSTR-1, GSTR-3B and 2A reconciliation, month by '
                    'month',
                onTap: () => context.push('/gst-reports'),
              ),
              AtriaNavRow(
                icon: Icons.inventory_2_outlined,
                title: 'Stock summary',
                subtitle: 'Quantity and value lying in stock, item wise',
                onTap: () => context.go('/stock'),
              ),
              AtriaNavRow(
                icon: Icons.receipt_long_outlined,
                title: 'Statement of account',
                subtitle: 'Party ledger with PDF and Excel download',
                // `/stock` and `/statements` are branch ROOTS, and this screen
                // lives in the reports branch. `push`ing a branch root makes
                // go_router append an ImperativeRouteMatch beside the shell
                // match, which hosts the page on the ROOT navigator — no rail,
                // no bottom bar, and Back unwinding to the previous page rather
                // than behaving like a tab. `go` switches the branch properly.
                onTap: () => context.go('/statements'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- Period selector ---------------------------------------------------

  static const _periodLabels = {
    _Period.thisMonth: 'This Month',
    _Period.thisQuarter: 'This Quarter',
    _Period.thisFY: 'This FY',
    _Period.custom: 'Custom',
  };

  Widget _periodSelector(_DateRange range) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              shrinkWrap: true,
              itemCount: _Period.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final period = _Period.values[index];
                final selected = _period == period;
                return ChoiceChip(
                  label: Text(
                    _periodLabels[period]!,
                    style: text.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  selected: selected,
                  showCheckmark: false,
                  onSelected: (_) => setState(() {
                    _period = period;
                    if (period == _Period.custom) {
                      _customFrom = DateTime(
                        DateTime.now().year,
                        DateTime.now().month,
                        1,
                      );
                      _customTo = DateTime.now();
                    }
                  }),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.event_available_rounded,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              if (_period == _Period.custom) ...[
                _datePill('From', _customFrom, (picked) {
                  setState(() => _customFrom = picked);
                }),
                const SizedBox(width: 8),
                _datePill('To', _customTo, (picked) {
                  setState(() => _customTo = picked);
                }),
              ] else
                Flexible(
                  child: Text(
                    range.label,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Outlined date pill used by the "Custom" period.
  Widget _datePill(
    String label,
    DateTime value,
    ValueChanged<DateTime> onPicked,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: value,
            firstDate: DateTime(2020),
            lastDate: DateTime.now(),
            helpText: label == 'From' ? 'Report starts on' : 'Report ends on',
          );
          if (picked != null) onPicked(picked);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: scheme.outline, width: 0.9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: text.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                Formatters.date(value),
                style: text.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Statement grid ----------------------------------------------------

  List<Widget> _statementGrid(
    ReportRepository repo,
    BoxConstraints constraints,
    _DateRange range,
  ) {
    final perRow = constraints.isLarge
        ? 4
        : constraints.isExpanded
        ? 3
        : 2;

    final cards = <_GridCard>[
      _GridCard(
        child: _PnlCard(repo: repo, range: range),
        wideOnCompact: true,
      ),
      _GridCard(
        child: _DayBookCard(
          repo: repo,
          day: _dayBookDay,
          onDayChanged: (day) => setState(() => _dayBookDay = day),
        ),
        wideOnCompact: true,
      ),
      _GridCard(
        child: _ReceivablesCard(repo: repo, range: range),
      ),
      _GridCard(child: _StockCard(repo: repo)),
    ];

    int spanFor(_GridCard card) {
      if (perRow <= 2) return card.wideOnCompact ? perRow : 1;
      return perRow == 3 ? 1 : 2;
    }

    // Greedy pack rows honouring each card's span.
    final rows = <List<_GridCard>>[];
    var current = <_GridCard>[];
    var remaining = perRow;
    for (final card in cards) {
      final span = spanFor(card);
      if (current.isNotEmpty && span > remaining) {
        rows.add(current);
        current = <_GridCard>[];
        remaining = perRow;
      }
      current.add(card);
      remaining -= span;
    }
    if (current.isNotEmpty) rows.add(current);

    return [
      for (final row in rows)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < row.length; i++) ...[
                    Expanded(flex: spanFor(row[i]), child: row[i].child),
                    if (i < row.length - 1) const SizedBox(width: 12),
                  ],
                ],
              ),
            ),
          ),
        ),
    ];
  }
}

class _GridCard {
  const _GridCard({required this.child, this.wideOnCompact = false});

  final Widget child;
  final bool wideOnCompact;
}

// ---------------------------------------------------------------------------
// Async plumbing
// ---------------------------------------------------------------------------

/// Renders the loading shimmer and error state once, so every report card only
/// has to describe its happy path.
class _SectionBuilder<T> extends StatelessWidget {
  const _SectionBuilder({
    required this.future,
    required this.builder,
    this.loadingHeight = 120,
    this.onRetry,
  });

  final Future<T> future;
  final Widget Function(T value) builder;
  final double loadingHeight;

  /// Re-runs the card's query. Every report here is a read of the local
  /// SQLite file, so a failure is always worth retrying — there is no
  /// partial-write state to be careful about.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _ShimmerBlock(height: loadingHeight);
        }
        if (snapshot.hasError) {
          // The exception itself used to be rendered verbatim, which put a
          // `SqliteException(...)` — a class name and a stack-frame-shaped
          // string — into a user-facing card. Keep it in debugPrint (no token
          // or secret is involved in a local report query) and give the user
          // a sentence plus a way out.
          debugPrint('reports: report card failed: ${snapshot.error}');
          return _CardEmpty(
            icon: Icons.error_outline_rounded,
            title: 'Could not load this report',
            message: onRetry == null
                ? 'Close and reopen the app, or try the report again.'
                : 'This report could not be read from your books. '
                    'Nothing has been changed — try again.',
            actionLabel: onRetry == null ? null : 'Try again',
            onAction: onRetry,
          );
        }
        final value = snapshot.data;
        if (value == null) {
          return const _CardEmpty(
            icon: Icons.inbox_outlined,
            title: 'Nothing to show',
          );
        }
        return builder(value);
      },
    );
  }
}

/// TDS and TCS for the selected period.
///
/// A card rather than a full report screen because there is exactly one number
/// an Indian small business needs from each: how much was deducted on its
/// purchases, how much it collected on its sales, and therefore how much goes
/// to the department on a challan by the 7th.
class _TaxAtSourceCard extends StatefulWidget {
  const _TaxAtSourceCard({required this.repo, required this.range});

  final ReportRepository repo;
  final _DateRange range;

  @override
  State<_TaxAtSourceCard> createState() => _TaxAtSourceCardState();
}

class _TaxAtSourceCardState extends State<_TaxAtSourceCard> {
  late Future<TaxAtSourceSummary> _future = widget.repo.taxAtSource(
    from: widget.range.from,
    to: widget.range.to,
  );

  void _reload() {
    _future = widget.repo.taxAtSource(
      from: widget.range.from,
      to: widget.range.to,
    );
  }

  @override
  void didUpdateWidget(covariant _TaxAtSourceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.range != widget.range || oldWidget.repo != widget.repo) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionBuilder<TaxAtSourceSummary>(
      future: _future,
      loadingHeight: 96,
      onRetry: () => setState(_reload),
      builder: (summary) {
        if (summary.isEmpty) {
          return const _CardEmpty(
            icon: Icons.percent_rounded,
            title: 'No tax at source in this period',
            message:
                'TDS on a purchase bill or TCS on an invoice will show '
                'here, with the total to deposit.',
          );
        }

        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        Widget row(String label, String note, Decimal amount) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: text.bodyMedium),
                    Text(
                      note,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                Formatters.money(amount),
                style: text.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );

        return AtriaCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (summary.tdsDeducted > Decimal.zero)
                row(
                  'TDS deducted on purchases',
                  '${summary.billsWithTds} bill(s) — paid to the government, '
                      'not to the supplier',
                  summary.tdsDeducted,
                ),
              if (summary.tcsCollected > Decimal.zero)
                row(
                  'TCS collected on sales',
                  '${summary.invoicesWithTcs} invoice(s) — held on the '
                      'customer\'s behalf',
                  summary.tcsCollected,
                ),
              const Divider(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'To deposit',
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    Formatters.money(summary.total),
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Challan ITNS-281, by the 7th of the month after the one '
                'the tax was deducted or collected in.',
                style: text.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CardEmpty extends StatelessWidget {
  const _CardEmpty({
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: icon,
      title: title,
      message: message,
      actionLabel: actionLabel,
      onAction: onAction,
      compact: true,
    );
  }
}

/// Gentle pulsing placeholder — cheaper than a full skeleton list and still
/// reads clearly as "loading" in both themes.
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.height, this.widthFactor = 1});

  final double height;
  final double widthFactor;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  late final Animation<double> _animation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FadeTransition(
      opacity: _animation,
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widget.widthFactor,
        child: Container(
          height: widget.height,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }
}

class _ShimmerBlock extends StatelessWidget {
  const _ShimmerBlock({this.height = 120});

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Shimmer(height: 12, widthFactor: 0.35),
          Spacer(),
          _Shimmer(height: 26, widthFactor: 0.62),
          Spacer(),
          _Shimmer(height: 14, widthFactor: 0.85),
          Spacer(),
          _Shimmer(height: 22, widthFactor: 0.45),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared card building blocks
// ---------------------------------------------------------------------------

Widget _cardTitle(BuildContext context, String title, String subtitle) {
  final text = Theme.of(context).textTheme;
  final scheme = Theme.of(context).colorScheme;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        title,
        style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      Text(
        subtitle,
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    ],
  );
}

Widget _subLabel(BuildContext context, String label) {
  final scheme = Theme.of(context).colorScheme;
  return Text(
    label,
    style: Theme.of(context).textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
    ),
  );
}

/// Trailing "+N more" line used by capped lists.
Widget _moreLine(BuildContext context, int extra) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Text(
      '+ $extra more ${extra == 1 ? 'entry' : 'entries'}',
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// 1. GST summary — the headline card
// ---------------------------------------------------------------------------

class _GstCard extends StatefulWidget {
  const _GstCard({required this.repo, required this.range});

  final ReportRepository repo;
  final _DateRange range;

  @override
  State<_GstCard> createState() => _GstCardState();
}

class _GstCardState extends State<_GstCard> {
  late Future<GstSummary> _future = widget.repo.gstSummary(
    from: widget.range.from,
    to: widget.range.to,
  );

  void _reload() {
    _future = widget.repo.gstSummary(
      from: widget.range.from,
      to: widget.range.to,
    );
  }

  @override
  void didUpdateWidget(covariant _GstCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.range != widget.range || oldWidget.repo != widget.repo) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = atriaColors(context);

    return AtriaCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Gradient header bar — the headline treatment.
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [colors.brandGradientStart, colors.brandGradientEnd],
              ),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.lg),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: AppRadius.smAll,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.receipt_long_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'GST Summary',
                        style: text.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        widget.range.label,
                        style: text.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.86),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Net payable',
                      style: text.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.86),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    FutureBuilder<GstSummary>(
                      future: _future,
                      builder: (context, snapshot) {
                        final payable = snapshot.data?.netPayable;
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return Text(
                            '…',
                            style: text.titleLarge?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          );
                        }
                        return MoneyText(
                          payable ?? Decimal.zero,
                          compact: true,
                          colorize: false,
                          style: text.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: _SectionBuilder<GstSummary>(
              future: _future,
              loadingHeight: 170,
              onRetry: () => setState(_reload),
              builder: (gst) => _gstBody(gst),
            ),
          ),
        ],
      ),
    );
  }

  Widget _gstBody(GstSummary gst) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);

    if (gst.outwardByRate.isEmpty &&
        gst.taxableValue == Decimal.zero &&
        gst.outputTax == Decimal.zero) {
      return const _CardEmpty(
        icon: Icons.receipt_outlined,
        title: 'No taxable sales in this period',
        message:
            'Create a sales invoice to see output tax and the '
            'rate-wise GSTR breakdown here.',
      );
    }

    final netPayable = gst.netPayable;
    final netColor = netPayable > Decimal.zero
        ? colors.negative
        : netPayable < Decimal.zero
        ? colors.positive
        : scheme.onSurface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _statTile('Output tax', gst.outputTax),
            _divider(),
            _statTile('Input tax (ITC)', gst.inputTax),
            if (gst.inputFromExpenses > Decimal.zero) ...[
              _divider(),
              _statTile('ITC on expenses', gst.inputFromExpenses),
            ],
            _divider(),
            _statTile('Net payable', netPayable, color: netColor),
          ],
        ),
        if (gst.inputFromExpenses > Decimal.zero) ...[
          const SizedBox(height: 10),
          Text(
            'ITC on expenses is the GST inside bills recorded as expenses, not '
            'as purchases. It counts as credit, and only the taxable part of '
            'the expense is a cost.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 18),
        _subLabel(context, 'Outward supplies — rate wise'),
        const SizedBox(height: 8),
        _rateTable(gst),
        if (gst.cess > Decimal.zero || gst.outputIgst > Decimal.zero) ...[
          const SizedBox(height: 10),
          Text(
            gst.outputIgst > Decimal.zero
                ? 'Inter-state supplies attract IGST instead of CGST + SGST.'
                : 'Cess is levied over and above the applicable GST rate.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _divider() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 0.9,
      height: 34,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: scheme.outline,
    );
  }

  Widget _statTile(String label, Decimal amount, {Color? color}) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: text.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          MoneyText(
            amount,
            compact: true,
            style: text.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rateTable(GstSummary gst) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final headerStyle = text.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final cellStyle = text.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    var taxable = Decimal.zero;
    var cgst = Decimal.zero;
    var sgst = Decimal.zero;
    var igst = Decimal.zero;
    var cess = Decimal.zero;
    for (final row in gst.outwardByRate) {
      taxable += row.taxableValue;
      cgst += row.cgst;
      sgst += row.sgst;
      igst += row.igst;
      cess += row.cess;
    }

    Widget headerCell(String label, {TextAlign align = TextAlign.right}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(label, style: headerStyle, textAlign: align),
      );
    }

    Widget amountCell(Decimal amount, {bool emphasize = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: MoneyText(
          amount,
          compact: true,
          colorize: false,
          // The headers above are right-aligned; the figures have to sit under
          // them or the column reads as skewed even when every number is right.
          textAlign: TextAlign.right,
          style: emphasize
              ? cellStyle?.copyWith(fontWeight: FontWeight.w700)
              : cellStyle,
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: const {
          0: FixedColumnWidth(52),
          1: FixedColumnWidth(94),
          2: FixedColumnWidth(72),
          3: FixedColumnWidth(72),
          4: FixedColumnWidth(72),
          5: FixedColumnWidth(64),
        },
        children: [
          TableRow(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: scheme.outline, width: 0.9),
              ),
            ),
            children: [
              headerCell('Rate', align: TextAlign.left),
              headerCell('Taxable'),
              headerCell('CGST'),
              headerCell('SGST'),
              headerCell('IGST'),
              headerCell('Cess'),
            ],
          ),
          for (final row in gst.outwardByRate)
            TableRow(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: scheme.outline, width: 0.7),
                ),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Text(
                    Formatters.percent(row.rate),
                    style: cellStyle?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                amountCell(row.taxableValue),
                amountCell(row.cgst),
                amountCell(row.sgst),
                amountCell(row.igst),
                amountCell(row.cess),
              ],
            ),
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Total',
                  style: (headerStyle ?? TextStyle()).copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: amountCell(taxable, emphasize: true),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: amountCell(cgst, emphasize: true),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: amountCell(sgst, emphasize: true),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: amountCell(igst, emphasize: true),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: amountCell(cess, emphasize: true),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Sales vs purchases — grouped bar chart
// ---------------------------------------------------------------------------

class _TrendCard extends StatefulWidget {
  const _TrendCard({required this.repo});

  final ReportRepository repo;

  @override
  State<_TrendCard> createState() => _TrendCardState();
}

class _TrendCardState extends State<_TrendCard> {
  static const _months = 6;

  /// NOT `late final`: Flutter reuses this State across a firm switch (the
  /// widget type and position never change), so a `late final` future was
  /// pinned to the *previous* firm's repository and the six-month trend kept
  /// showing the old business's numbers. Every sibling card
  /// (`_GstCard`, `_PnlCard`, `_DayBookCard`, `_ReceivablesCard`,
  /// `_TaxAtSourceCard`) already re-issued on `repo`; these two were the
  /// outliers.
  late Future<List<MonthlyPoint>> _future = widget.repo.monthlyTrend(
    months: _months,
  );

  void _reload() {
    _future = widget.repo.monthlyTrend(months: _months);
  }

  @override
  void didUpdateWidget(covariant _TrendCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repo != widget.repo) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);

    return AtriaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Sales vs Purchases',
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Last $_months months',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _legendDot(colors.brandGradientStart, 'Sales'),
                  const SizedBox(width: 12),
                  _legendDot(colors.saffronGradientEnd, 'Purchases'),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          _SectionBuilder<List<MonthlyPoint>>(
            future: _future,
            loadingHeight: 220,
            onRetry: () => setState(_reload),
            builder: (points) {
              final hasData = points.any(
                (p) => p.sales > Decimal.zero || p.purchases > Decimal.zero,
              );
              if (!hasData) {
                return const _CardEmpty(
                  icon: Icons.show_chart_rounded,
                  title: 'No trading activity yet',
                  message: 'Record a sale or purchase to build the trend.',
                );
              }
              return SizedBox(
                height: 220,
                child: BarChart(_barChartData(points)),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: const BorderRadius.all(Radius.circular(AppRadius.xs)),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: text.labelSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  BarChartData _barChartData(List<MonthlyPoint> points) {
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);
    final text = Theme.of(context).textTheme;

    final peak = points.fold<double>(0, (max, p) {
      final s = p.sales.toDouble();
      final b = p.purchases.toDouble();
      return (max > s && max > b) ? max : (s > b ? s : b);
    });
    final maxY = peak <= 0 ? 1.0 : peak * 1.18;
    final interval = _niceInterval(maxY);
    final rodWidth = points.length > 4 ? 8.0 : 12.0;

    final axisStyle = text.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return BarChartData(
      maxY: maxY,
      minY: 0,
      alignment: BarChartAlignment.spaceEvenly,
      groupsSpace: 22,
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          tooltipRoundedRadius: 8,
          tooltipMargin: 10,
          getTooltipColor: (_) => scheme.inverseSurface,
          getTooltipItem: (group, groupIndex, rod, rodIndex) {
            final isSales = rodIndex == 0;
            return BarTooltipItem(
              '${isSales ? 'Sales' : 'Purchases'}\n'
              '${Formatters.monthYear(points[groupIndex].month)}\n'
              '${Formatters.money(Decimal.parse(rod.toY.toStringAsFixed(2)))}',
              (text.bodySmall ?? const TextStyle()).copyWith(
                color: scheme.onInverseSurface,
                fontWeight: FontWeight.w700,
                height: 1.35,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              textAlign: TextAlign.center,
            );
          },
        ),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        leftTitles: AxisTitles(
          axisNameSize: 0,
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 52,
            interval: interval,
            getTitlesWidget: (value, meta) => SideTitleWidget(
              axisSide: meta.axisSide,
              fitInside: SideTitleFitInsideData.fromTitleMeta(
                meta,
                enabled: true,
                distanceFromEdge: 4,
              ),
              child: MoneyText(
                Decimal.parse(value.toStringAsFixed(0)),
                compact: true,
                colorize: false,
                style: axisStyle,
              ),
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          axisNameSize: 0,
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 26,
            getTitlesWidget: (value, meta) {
              final index = value.toInt();
              if (index < 0 || index >= points.length) {
                return const SizedBox.shrink();
              }
              return SideTitleWidget(
                axisSide: meta.axisSide,
                child: Text(
                  Formatters.monthDay(points[index].month),
                  style: axisStyle,
                ),
              );
            },
          ),
        ),
      ),
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: interval,
        getDrawingHorizontalLine: (value) => FlLine(
          color: scheme.outline,
          strokeWidth: 0.6,
          dashArray: const [4, 4],
        ),
        checkToShowHorizontalLine: (value) => value != 0,
      ),
      borderData: FlBorderData(show: false),
      barGroups: [
        for (var i = 0; i < points.length; i++)
          BarChartGroupData(
            x: i,
            barsSpace: 4,
            barRods: [
              BarChartRodData(
                toY: points[i].sales.toDouble(),
                color: colors.brandGradientStart,
                width: rodWidth,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                ),
              ),
              BarChartRodData(
                toY: points[i].purchases.toDouble(),
                color: colors.saffronGradientEnd,
                width: rodWidth,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Profit & loss
// ---------------------------------------------------------------------------

class _PnlCard extends StatefulWidget {
  const _PnlCard({required this.repo, required this.range});

  final ReportRepository repo;
  final _DateRange range;

  @override
  State<_PnlCard> createState() => _PnlCardState();
}

class _PnlCardState extends State<_PnlCard> {
  static const _maxRows = 4;

  late Future<ProfitAndLoss> _future = widget.repo.profitAndLoss(
    from: widget.range.from,
    to: widget.range.to,
  );

  void _reload() {
    _future = widget.repo.profitAndLoss(
      from: widget.range.from,
      to: widget.range.to,
    );
  }

  @override
  void didUpdateWidget(covariant _PnlCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.range != widget.range || oldWidget.repo != widget.repo) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AtriaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(
            context,
            'Profit & Loss',
            'Net result for ${widget.range.label}',
          ),
          const SizedBox(height: 10),
          _SectionBuilder<ProfitAndLoss>(
            future: _future,
            loadingHeight: 190,
            onRetry: () => setState(_reload),
            builder: (pnl) => _pnlBody(pnl),
          ),
        ],
      ),
    );
  }

  Widget _pnlBody(ProfitAndLoss pnl) {
    final colors = atriaColors(context);

    if (pnl.incomeRows.isEmpty && pnl.expenseRows.isEmpty) {
      return const _CardEmpty(
        icon: Icons.account_balance_outlined,
        title: 'No books for this period',
        message:
            'Sales, purchases or expenses recorded in this window '
            'appear here as a statement.',
      );
    }

    final shownIncome = pnl.incomeRows.take(_maxRows).toList();
    final shownExpenses = pnl.expenseRows.take(_maxRows).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subLabel(context, 'Income'),
        const SizedBox(height: 4),
        for (final row in shownIncome) _pnlRow(row),
        if (pnl.incomeRows.length > _maxRows)
          _moreLine(context, pnl.incomeRows.length - _maxRows),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _totalRow('Total income', pnl.totalIncome),
        ),
        const SizedBox(height: 12),
        Divider(color: Theme.of(context).colorScheme.outline, height: 1),
        const SizedBox(height: 12),
        _subLabel(context, 'Expenses'),
        const SizedBox(height: 4),
        for (final row in shownExpenses) _pnlRow(row),
        if (pnl.expenseRows.length > _maxRows)
          _moreLine(context, pnl.expenseRows.length - _maxRows),
        // The stock adjustment only appears when the firm actually tracks
        // stock, so a services business still reads as a plain list.
        if (pnl.hasStockAdjustment) ...[
          const SizedBox(height: 6),
          _pnlRow(PnLRow('Opening stock', pnl.openingStock)),
          _pnlRow(PnLRow('Closing stock', -pnl.closingStock)),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _totalRow('Cost of goods sold', pnl.costOfGoodsSold),
          ),
          const SizedBox(height: 6),
          Text(
            'Purchases are shown as “Cost of goods purchased” above; opening '
            'stock is added and closing stock deducted, so only what was sold '
            'is charged to this period.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _totalRow('Total expenses', pnl.totalExpenses),
        ),
        const SizedBox(height: 14),
        _netProfitTile(pnl.netProfit, colors),
      ],
    );
  }

  Widget _pnlRow(PnLRow row) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              row.label,
              style: text.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          MoneyText(
            row.amount,
            compact: true,
            colorize: false,
            style: text.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalRow(String label, Decimal amount) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: text.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        MoneyText(
          amount,
          compact: true,
          colorize: false,
          style: text.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _netProfitTile(Decimal netProfit, AtriaColorsExtension colors) {
    final text = Theme.of(context).textTheme;
    final profitable = netProfit >= Decimal.zero;
    final surface = profitable ? colors.successSurface : colors.dangerSurface;
    final onSurface = profitable
        ? colors.onSuccessSurface
        : colors.onDangerSurface;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Icon(
            profitable
                ? Icons.trending_up_rounded
                : Icons.trending_down_rounded,
            color: onSurface,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              profitable ? 'Net profit' : 'Net loss',
              style: text.titleSmall?.copyWith(
                color: onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          MoneyText(
            netProfit,
            compact: true,
            colorize: false,
            style: text.titleMedium?.copyWith(
              color: onSurface,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 4. Receivables & payables
// ---------------------------------------------------------------------------

class _ReceivablesCard extends StatefulWidget {
  const _ReceivablesCard({required this.repo, required this.range});

  final ReportRepository repo;
  final _DateRange range;

  @override
  State<_ReceivablesCard> createState() => _ReceivablesCardState();
}

class _ReceivablesCardState extends State<_ReceivablesCard> {
  late Future<DashboardSummary> _future = widget.repo.dashboard(
    from: widget.range.from,
    to: widget.range.to,
  );

  void _reload() {
    _future = widget.repo.dashboard(
      from: widget.range.from,
      to: widget.range.to,
    );
  }

  @override
  void didUpdateWidget(covariant _ReceivablesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.range != widget.range || oldWidget.repo != widget.repo) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AtriaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(context, 'Receivables & Payables', 'Outstanding books'),
          const SizedBox(height: 10),
          _SectionBuilder<DashboardSummary>(
            future: _future,
            loadingHeight: 150,
            onRetry: () => setState(_reload),
            builder: (summary) => _body(summary),
          ),
        ],
      ),
    );
  }

  Widget _body(DashboardSummary summary) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);

    final net = summary.receivable - summary.payable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _duo('You will receive', summary.receivable, colors.positive),
        const SizedBox(height: 8),
        _duo('You will pay', summary.payable, colors.negative),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Net position',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                MoneyText(
                  net,
                  compact: true,
                  signMode: MoneySignMode.always,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (summary.overdueCount > 0) ...[
          const SizedBox(height: 10),
          _warningChip(
            '${summary.overdueCount} overdue '
            '${summary.overdueCount == 1 ? 'invoice' : 'invoices'}',
          ),
        ],
      ],
    );
  }

  Widget _duo(String label, Decimal amount, Color color) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            label,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 8),
        MoneyText(
          amount,
          compact: true,
          colorize: false,
          style: text.titleMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _warningChip(String label) {
    final text = Theme.of(context).textTheme;
    final colors = atriaColors(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.warningSurface,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: colors.onWarningSurface,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: text.labelSmall?.copyWith(
              color: colors.onWarningSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 5. Day book
// ---------------------------------------------------------------------------

class _DayBookCard extends StatefulWidget {
  const _DayBookCard({
    required this.repo,
    required this.day,
    required this.onDayChanged,
  });

  final ReportRepository repo;
  final DateTime day;
  final ValueChanged<DateTime> onDayChanged;

  @override
  State<_DayBookCard> createState() => _DayBookCardState();
}

class _DayBookCardState extends State<_DayBookCard> {
  static const _maxLines = 5;

  late Future<List<DayBookLine>> _future = widget.repo.dayBook(day: widget.day);

  void _reload() {
    _future = widget.repo.dayBook(day: widget.day);
  }

  @override
  void didUpdateWidget(covariant _DayBookCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.day != widget.day || oldWidget.repo != widget.repo) {
      _reload();
    }
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.day,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: 'Day book for',
    );
    if (picked != null) widget.onDayChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return AtriaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _cardTitle(
                  context,
                  'Day Book',
                  'Every entry '
                      'on one day',
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _pickDay,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      border: Border.all(color: scheme.outline, width: 0.9),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.calendar_today_rounded,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          Formatters.date(widget.day),
                          style: text.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SectionBuilder<List<DayBookLine>>(
            future: _future,
            loadingHeight: 190,
            onRetry: () => setState(_reload),
            builder: (lines) => _body(lines),
          ),
        ],
      ),
    );
  }

  Widget _body(List<DayBookLine> lines) {
    if (lines.isEmpty) {
      return _CardEmpty(
        icon: Icons.menu_book_rounded,
        title: 'Nothing on this day',
        message:
            'No sales, purchases, payments or expenses were recorded '
            'on ${Formatters.date(widget.day)}.',
      );
    }

    var total = Decimal.zero;
    for (final line in lines) {
      total += line.amount;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < lines.length && i < _maxLines; i++) ...[
          _dayBookRow(lines[i]),
          const SizedBox(height: 8),
        ],
        if (lines.length > _maxLines)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _moreLine(context, lines.length - _maxLines),
          ),
        Divider(color: Theme.of(context).colorScheme.outline, height: 1),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Total movement',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              MoneyText(
                total,
                compact: true,
                colorize: false,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dayBookRow(DayBookLine line) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final style = _dayBookStyle(context, line.type);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: style.color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            style.label,
            style: text.labelSmall?.copyWith(
              color: style.color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                line.party,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                line.number,
                style: text.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        MoneyText(
          line.amount,
          compact: true,
          colorize: false,
          style: text.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

({Color color, String label}) _dayBookStyle(BuildContext context, String type) {
  final colors = atriaColors(context);
  return switch (type) {
    'Sales' => (color: colors.brandGradientStart, label: 'Sales'),
    'Purchase' => (color: colors.saffronGradientEnd, label: 'Purchase'),
    'Expense' => (color: const Color(0xFF7C3AED), label: 'Expense'),
    'Receipt' => (color: colors.positive, label: 'Receipt'),
    'Payment' => (color: colors.negative, label: 'Payment'),
    _ => (color: Theme.of(context).colorScheme.onSurfaceVariant, label: type),
  };
}

// ---------------------------------------------------------------------------
// 6. Stock summary shortcut
// ---------------------------------------------------------------------------

class _StockCard extends StatefulWidget {
  const _StockCard({required this.repo});

  final ReportRepository repo;

  @override
  State<_StockCard> createState() => _StockCardState();
}

class _StockCardState extends State<_StockCard> {
  /// NOT `late final`: the State is reused across a firm switch, so the
  /// stock valuation kept reading the previous firm's items and quantities.
  /// Matches `_TrendCardState` and the other five cards.
  late Future<List<StockSummaryRow>> _future = widget.repo.stockSummary();

  void _reload() {
    _future = widget.repo.stockSummary();
  }

  @override
  void didUpdateWidget(covariant _StockCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repo != widget.repo) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);

    return AtriaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(context, 'Stock Summary', 'Valuation at sale price'),
          const SizedBox(height: 12),
          _SectionBuilder<List<StockSummaryRow>>(
            future: _future,
            loadingHeight: 150,
            onRetry: () => setState(_reload),
            builder: (rows) {
              var saleValue = Decimal.zero;
              var lowCount = 0;
              for (final row in rows) {
                saleValue += row.saleValue;
                if (row.isLow) lowCount++;
              }

              if (rows.isEmpty) {
                return const _CardEmpty(
                  icon: Icons.inventory_2_outlined,
                  title: 'No tracked items',
                  message:
                      'Add inventory with stock tracking to value '
                      'your stock.',
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Stock value',
                    style: text.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  MoneyText(
                    saleValue,
                    compact: true,
                    colorize: false,
                    style: text.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        lowCount > 0
                            ? Icons.warning_amber_rounded
                            : Icons.check_circle_rounded,
                        size: 16,
                        color: lowCount > 0 ? colors.warning : colors.positive,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          lowCount > 0
                              ? '$lowCount ${lowCount == 1 ? 'item' : 'items'} '
                                    'need restocking'
                              : 'All items above their alert level',
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  FilledButton.tonalIcon(
                    // Branch root — see the note on the Stock summary row above.
                    onPressed: () => context.go('/stock'),
                    icon: const Icon(Icons.inventory_2_rounded, size: 18),
                    label: const Text('Open stock'),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
