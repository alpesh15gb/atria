import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/report_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/status_chip.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // These are FutureProviders, so they resolve once and stay cached. Without
    // an explicit refresh, a sale recorded on another tab is never reflected
    // here — the KPIs and "recent invoices" would show a stale month.
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // FutureProviders cache after the first resolve; calling the repository
      // directly (the old "refresh") discarded its result and refreshed
      // nothing. Invalidate the watched providers instead.
      _refresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  void _refresh() {
    ref.invalidate(_dashboardProvider);
    ref.invalidate(_trendProvider);
  }

  @override
  Widget build(BuildContext context) {
    final firm = ref.watch(activeFirmProvider).valueOrNull;
    final reports = ref.watch(reportRepositoryProvider);

    final now = DateTime.now();
    final from = DateTime(now.year, now.month, 1);
    final hour = now.hour;
    final greeting = hour < 12
        ? 'Good Morning'
        : hour < 17
            ? 'Good Afternoon'
            : 'Good Evening';

    return Scaffold(
      body: RefreshIndicator(
        // A visible way to pick up changes made elsewhere in the app, since
        // these FutureProviders otherwise cache until the firm changes.
        onRefresh: () async {
          _refresh();
          // Hold the indicator briefly so the pull is felt rather than
          // vanishing before the provider resolves.
          await Future<void>.delayed(const Duration(milliseconds: 350));
        },
        child: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            stretch: true,
            toolbarHeight: 72,
            titleSpacing: 0,
            // 2026 greeting header: "Good Morning, <Business>" like the
            // reference home, with the FY as the quiet second line.
            title: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    greeting,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  Text(
                    firm?.name ?? 'Atria',
                    style: Theme.of(context).textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            actions: [
              IconButton.filledTonal(
                onPressed: () => _showFirmSwitcher(context),
                icon: const Icon(Icons.business_center_outlined, size: 20),
                tooltip: 'Switch business',
                style: IconButton.styleFrom(
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                onPressed: () => context.push('/settings'),
                icon: const Icon(PhosphorIconsRegular.gear, size: 20),
                tooltip: 'Settings',
                style: IconButton.styleFrom(
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(width: 16),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (reports == null)
                  const _NoFirmState()
                else ...[
                  _HeroCard(firm: firm, reports: reports, from: from),
                  const SizedBox(height: 16),
                  _QuickActions(),
                  const SizedBox(height: 20),
                  _KpiGrid(reports: reports, from: from),
                  const SizedBox(height: 20),
                  _TrendSection(reports: reports),
                  const SizedBox(height: 20),
                  _RecentInvoices(),
                  const SizedBox(height: 20),
                  _AlertsSection(reports: reports),
                ],
              ]),
            ),
          ),
        ],
      ),
      ),
    );
  }

  void _showFirmSwitcher(BuildContext context) {
    final firms = ref.read(allFirmsProvider).valueOrNull ?? [];
    final activeId = ref.read(activeFirmIdProvider);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: Text('Your businesses',
                      style: Theme.of(sheetContext).textTheme.titleMedium),
                ),
                RadioGroup<String>(
                  groupValue: activeId,
                  onChanged: (value) {
                    if (value == null) return;
                    ref.read(activeFirmIdProvider.notifier).select(value);
                    ref.read(firmRepositoryProvider).setDefault(value);
                    Navigator.of(sheetContext).pop();
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final f in firms)
                        RadioListTile<String>(
                          value: f.id,
                          title: Text(f.name),
                          subtitle: Text(
                            (f.gstin ?? 'Unregistered').toUpperCase(),
                            style: Theme.of(sheetContext).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      context.push('/onboarding/firm-setup');
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add another business'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _NoFirmState extends StatelessWidget {
  const _NoFirmState();

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: PhosphorIconsRegular.books,
      title: 'No business yet',
      message: 'Create your first business or start with sample data to '
          'explore Atria end to end.',
      actionLabel: 'Set up business',
      onAction: () => context.push('/onboarding/firm-setup'),
    );
  }
}

/// The brand hero: gradient card with the headline sales number and the
/// two balances that matter most to a business owner.
class _HeroCard extends ConsumerWidget {
  const _HeroCard({required this.firm, required this.reports, required this.from});

  final FirmEntity? firm;
  final ReportRepository reports;
  final DateTime from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final future = ref.watch(_dashboardProvider(from));

    return future.when(
      loading: () => _heroSkeleton(context),
      // A failed query used to render the skeleton forever — the dashboard
      // looked stuck loading with no way to retry.
      error: (e, _) => AtriaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(PhosphorIconsRegular.warningCircle,
                    size: 18, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                Text('Could not load today’s numbers',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text('$e',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => ref.invalidate(_dashboardProvider(from)),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (summary) {
        final isDark = Theme.of(context).brightness == Brightness.dark;

        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.xl)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: const [0, 0.55, 1],
              colors: isDark
                  ? [
                      const Color(0xFF7C3AED),
                      const Color(0xFF5B21B6),
                      const Color(0xFF2E1065),
                    ]
                  : AppColors.heroGradient,
            ),
            boxShadow:
                isDark ? null : AppShadows.cardHigh,
          ),
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Sales',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        Formatters.monthYear(DateTime.now()),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  // The reference card's signature tile: a soft white chip
                  // with the brand mark, top-right.
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: const Icon(
                      PhosphorIconsFill.stack,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const SizedBox(height: 8),
              Text(
                Formatters.money(summary.totalSales),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 38,
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                  letterSpacing: -1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${summary.invoiceCount} invoice${summary.invoiceCount == 1 ? '' : 's'} this month',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 18),
              IntrinsicHeight(
                child: Row(
                  children: [
                    _heroStat(
                      context,
                      'To receive',
                      Formatters.moneyCompact(summary.receivable),
                      PhosphorIconsRegular.arrowDownLeft,
                    ),
                    VerticalDivider(
                      width: 28,
                      color: Colors.white.withValues(alpha: 0.22),
                      indent: 4,
                      endIndent: 4,
                    ),
                    _heroStat(
                      context,
                      'To pay',
                      Formatters.moneyCompact(summary.payable),
                      PhosphorIconsRegular.arrowUpRight,
                    ),
                    VerticalDivider(
                      width: 28,
                      color: Colors.white.withValues(alpha: 0.22),
                      indent: 4,
                      endIndent: 4,
                    ),
                    _heroStat(
                      context,
                      'Stock value',
                      Formatters.moneyCompact(summary.stockValue),
                      PhosphorIconsRegular.warehouse,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _heroStat(BuildContext context, String label, String value, IconData icon) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: Colors.white.withValues(alpha: 0.8)),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroSkeleton(BuildContext context) {
    return Container(
      height: 172,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.xl)),
      ),
    );
  }
}

final _dashboardProvider =
    FutureProvider.family<DashboardSummary, DateTime>((ref, from) async {
  final reports = ref.watch(reportRepositoryProvider);
  if (reports == null) {
    return DashboardSummary.empty();
  }
  return reports.dashboard(from: from, to: DateTime.now());
});

class _QuickActions extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);
    final actions = <_QuickAction>[
      _QuickAction(
        label: 'New Invoice',
        icon: PhosphorIconsRegular.receipt,
        color: colors.brandGradientStart,
        onTap: () => context.push('/sales/new?type=invoice'),
      ),
      _QuickAction(
        label: 'Add Item',
        icon: PhosphorIconsRegular.cube,
        color: colors.warning,
        onTap: () => context.push('/items/new'),
      ),
      _QuickAction(
        label: 'Add Party',
        icon: PhosphorIconsRegular.userPlus,
        color: colors.positive,
        onTap: () => context.push('/parties/new'),
      ),
      _QuickAction(
        label: 'Reports',
        icon: PhosphorIconsRegular.chartBar,
        color: scheme.secondary,
        onTap: () => context.push('/reports'),
      ),
    ];
    return Row(
      children: [
        for (final a in actions) ...[
          Expanded(child: _QuickActionButton(action: a)),
          if (a != actions.last) const SizedBox(width: 12),
        ],
      ],
    );
  }
}

class _QuickAction {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _QuickAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({required this.action});

  final _QuickAction action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Reference-style quick actions: borderless card, soft tinted icon tile.
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: action.onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: AppShadows.card,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: action.color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                alignment: Alignment.center,
                child: Icon(action.icon, size: 21, color: action.color),
              ),
              const SizedBox(height: 8),
              Text(
                action.label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KpiGrid extends ConsumerWidget {
  const _KpiGrid({required this.reports, required this.from});

  final ReportRepository reports;
  final DateTime from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final future = ref.watch(_dashboardProvider(from));
    final colors = atriaColors(context);
    final scheme = Theme.of(context).colorScheme;

    return future.when(
      loading: () => const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (e, _) => AtriaCard(
        child: Text('Could not load summary: $e',
            style: TextStyle(color: scheme.error)),
      ),
      data: (summary) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final crossCount = constraints.isCompact ? 2 : 4;
            return GridView.count(
              crossAxisCount: crossCount,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: constraints.isCompact ? 1.05 : 1.15,
              children: [
                _KpiCard(
                  label: 'Purchases',
                  amount: summary.totalPurchases,
                  icon: PhosphorIconsRegular.shoppingCart,
                  tint: colors.saffronGradientStart,
                  onTap: () => context.push('/purchase'),
                ),
                _KpiCard(
                  label: 'Expenses',
                  amount: summary.totalExpenses,
                  icon: PhosphorIconsRegular.moneyWavy,
                  tint: colors.negative,
                  onTap: () => context.push('/expenses'),
                ),
                _KpiCard(
                  label: 'GST payable',
                  amount: summary.gstPayable,
                  icon: PhosphorIconsRegular.receipt,
                  tint: colors.warning,
                  onTap: () => context.push('/reports'),
                ),
                _KpiCard(
                  label: 'Net received',
                  amount: summary.totalReceived - summary.totalPaid,
                  icon: PhosphorIconsRegular.bank,
                  tint: colors.positive,
                  onTap: () => context.push('/reports'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.label,
    required this.amount,
    required this.icon,
    required this.tint,
    required this.onTap,
  });

  final String label;
  final Decimal amount;
  final IconData icon;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: AppShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 18, color: tint),
              ),
              const Spacer(),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: MoneyText(
                  amount,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                  colorize: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrendSection extends ConsumerWidget {
  const _TrendSection({required this.reports});

  final ReportRepository reports;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Sales vs Purchases',
          subtitle: 'Last 6 months',
          actionLabel: 'Reports',
          onAction: () => context.push('/reports'),
        ),
        _TrendChart(reports: reports),
      ],
    );
  }
}

class _TrendChart extends ConsumerWidget {
  const _TrendChart({required this.reports});

  final ReportRepository reports;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final future = ref.watch(_trendProvider);

    return future.when(
      loading: () => const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (e, _) => AtriaCard(
        child: Text('Could not load trend: $e',
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ),
      data: (points) {
        if (points.isEmpty) {
          return AtriaCard(
            child: EmptyState(
              icon: PhosphorIconsRegular.chartLine,
              title: 'No data yet',
              message: 'Sales and purchases appear here once you create them.',
              compact: true,
            ),
          );
        }
        return _BarsCard(points: points);
      },
    );
  }
}

final _trendProvider = FutureProvider.autoDispose<List<MonthlyPoint>>((ref) async {
  final reports = ref.watch(reportRepositoryProvider);
  if (reports == null) return const [];
  return reports.monthlyTrend(months: 6);
});

/// Layout constants for [_BarsCard], kept at the top so the card and the bar
/// heights can't drift apart.
class _TrendBars {
  const _TrendBars._();

  /// Total height of the chart box.
  static const double height = 150;

  /// Height the bars may actually fill: the month label and its gap sit below
  /// them inside the same fixed box.
  static const double barHeight = height - 24;
}

class _BarsCard extends StatelessWidget {
  const _BarsCard({required this.points});

  final List<MonthlyPoint> points;

  double get _maxValue {    var max = 0.0;
    for (final p in points) {
      max = [
        max,
        p.sales.toDouble(),
        p.purchases.toDouble(),
      ].reduce((a, b) => a > b ? a : b);
    }
    return max == 0 ? 1.0 : max;
  }

  @override
  Widget build(BuildContext context) {
    final max = _maxValue;
    final colors = atriaColors(context);
    final scheme = Theme.of(context).colorScheme;

    return AtriaCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        children: [
          Row(
            children: [
              _legend(context, 'Sales', colors.brandGradientStart),
              const SizedBox(width: 16),
              _legend(context, 'Purchases', colors.saffronGradientStart),
            ],
          ),
          const SizedBox(height: 16),
          // The bars share this box with the month label beneath them, so the
          // full 150px is not all theirs — sizing a bar to 150 * ratio pushed
          // the tallest pair past the bottom of the card.
          const SizedBox(height: _TrendBars.height),
          LayoutBuilder(
            builder: (context, constraints) {
              final groupWidth = constraints.maxWidth / points.length;
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final p in points)
                    SizedBox(
                      width: groupWidth * 0.72,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              _bar(
                                context,
                                height: _TrendBars.barHeight *
                                    (p.sales.toDouble() / max),
                                color: colors.brandGradientStart,
                              ),
                              const SizedBox(width: 4),
                              _bar(
                                context,
                                height: _TrendBars.barHeight *
                                    (p.purchases.toDouble() / max),
                                color: colors.saffronGradientStart,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            Formatters.monthYear(p.month).substring(0, 3),
                            style:
                                Theme.of(context).textTheme.labelSmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _bar(BuildContext context, {required double height, required Color color}) {
    return Container(
      width: 16,
      height: height.clamp(2, double.infinity),
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(5),
          topRight: Radius.circular(5),
        ),
      ),
    );
  }

  Widget _legend(BuildContext context, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}

class _RecentInvoices extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(salesRepositoryProvider);
    if (sales == null) return const SizedBox.shrink();

    final invoices = sales.watchList(docType: 'invoice', limit: 5);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Recent invoices',
          actionLabel: 'View all',
          onAction: () => context.push('/sales'),
        ),
        StreamBuilder(
          stream: invoices,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const AtriaCard(
                child: SizedBox(
                  height: 72,
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              );
            }
            final data = snapshot.data ?? const [];
            if (data.isEmpty) {
              return AtriaCard(
                child: EmptyState(
                  icon: PhosphorIconsRegular.receipt,
                  title: 'No invoices yet',
                  message: 'Create your first GST invoice to see it here.',
                  actionLabel: 'New invoice',
                  onAction: () => context.push('/sales/new?type=invoice'),
                  compact: true,
                ),
              );
            }
            return Column(
              children: [
                for (final invoice in data)
                  _InvoiceTile(invoice: invoice),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _InvoiceTile extends StatelessWidget {
  const _InvoiceTile({required this.invoice});

  final SalesInvoiceEntity invoice;

  @override
  Widget build(BuildContext context) {
    final colors = atriaColors(context);
    final initials = _initials(invoice.partyName ?? '?');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          onTap: () => context.push('/sales/detail/${invoice.id}'),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              boxShadow: AppShadows.card,
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: colors.brandGradientStart.withValues(alpha: 0.14),
                  child: Text(
                    initials,
                    style: TextStyle(
                      color: colors.brandGradientStart,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        invoice.partyName ?? 'Walk-in customer',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${invoice.number} • ${Formatters.date(invoice.invoiceDate)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // A cancelled invoice keeps its old payment status, so the
                // pill would call a voided invoice "Unpaid".
                invoice.status == 'cancelled'
                    ? StatusChip.doc('cancelled')
                    : StatusChip.payment(invoice.paymentStatus),
                const SizedBox(width: 10),
                MoneyText(
                  Decimal.parse(invoice.grandTotal.toString()),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                  colorize: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1))
        .toUpperCase();
  }
}

class _AlertsSection extends ConsumerWidget {
  const _AlertsSection({required this.reports});

  final ReportRepository reports;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final future = ref.watch(_dashboardProvider(DateTime(DateTime.now().year,
        DateTime.now().month, 1)));

    return future.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          children: [
            Icon(PhosphorIconsRegular.warningCircle,
                size: 16, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Could not load alerts — $e',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            TextButton(
              onPressed: () => ref.invalidate(_dashboardProvider(DateTime(
                  DateTime.now().year, DateTime.now().month, 1))),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (summary) {
        if (summary.lowStockCount == 0 && summary.overdueCount == 0) {
          return const SizedBox.shrink();
        }
        final colors = atriaColors(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(title: 'Needs attention'),
            Row(
              children: [
                if (summary.lowStockCount > 0) ...[
                  Expanded(
                    child: _AlertCard(
                      icon: PhosphorIconsRegular.package,
                      tint: colors.warning,
                      title: 'Low stock',
                      body:
                          '${summary.lowStockCount} item${summary.lowStockCount == 1 ? '' : 's'} at or below the alert level',
                      onTap: () => context.push('/stock'),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                if (summary.overdueCount > 0) ...[
                  Expanded(
                    child: _AlertCard(
                      icon: PhosphorIconsRegular.warning,
                      tint: colors.negative,
                      title: 'Overdue',
                      body:
                          '${summary.overdueCount} invoice${summary.overdueCount == 1 ? '' : 's'} past the due date',
                      // Straight to the reminders list — the action a user
                      // takes on overdue invoices is nudging the party.
                      onTap: () => context.push('/payment-reminders'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.icon,
    required this.tint,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: tint.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: AppShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: tint),
              const SizedBox(height: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: tint,
                    ),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
