import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/report_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atria_avatar.dart';
import '../../core/responsive/platform_ui.dart';
import '../../shared/widgets/atria_create_menu.dart';
import '../../shared/widgets/mobile_create_grid.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/status_chip.dart';

/// Every link on this page that points at a **branch root** — `/sales`,
/// `/purchase`, `/reports`, `/stock`, `/expenses`, `/settings` — uses `go`,
/// never `push`.
///
/// Each of those paths is the root of a `StatefulShellBranch` and no branch
/// route sets a `parentNavigatorKey`. go_router resolves an imperative push by
/// walking the *current* match list until something is incompatible with the
/// target, and its reuse test
/// (`RouteMatchList._createNewMatchUntilIncompatible`) only reuses a shell
/// when `otherMatches.last is ShellRouteMatch`. Coming from any branch, the
/// last entry of that list is a plain `RouteMatch`, so the reuse branch is
/// skipped and the `ImperativeRouteMatch` is appended as a **top-level sibling
/// of the `StatefulShellMatch`**. The page then renders on the ROOT navigator:
/// no nav rail, no bottom bar, and on Android Back unwinds to the pre-push
/// screen instead of behaving like a tab. `go` replaces the match list, so the
/// shell stays one instance and the branch really switches.
///
/// Deep links into a branch — `/sales/new`, `/sales/detail/<id>` — and the
/// three routes that sit outside the shell on purpose (`/pos`,
/// `/payment-reminders`, `/onboarding/firm-setup`) are pushed as before.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with WidgetsBindingObserver {
  /// The phone's **Quick Access** tiles.
  ///
  /// Reports and Payments are here because they are what a shopkeeper opens
  /// between serving two customers, and neither is a tap away on the bottom bar —
  /// that has Home, Bills, Products, Parties, More. Stock sits behind Items, so
  /// it is the one destination duplicated here.
  ///
  /// **Not the reference's Quick Access.** Four of its eight tiles are e-way
  /// bills, e-invoicing, GST filing and bank reconciliation, none of which this
  /// app has. Copying the row and blanking half of it would leave a grid of gaps
  /// on the busiest screen in the app.
  static const List<({String route, String label, IconData icon})> _quickAccess =
      [
    (route: '/reports', label: 'Reports', icon: Icons.insights_outlined),
    (route: '/payments', label: 'Payments', icon: Icons.receipt_long_outlined),
    (route: '/stock', label: 'Stock', icon: Icons.inventory_2_outlined),
    (route: '/items', label: 'Products', icon: Icons.category_outlined),
    (route: '/parties?type=customer', label: 'Parties', icon: Icons.groups_outlined),
    (route: '/ledger', label: 'Ledger', icon: Icons.menu_book_outlined),
    (route: '/settings', label: 'Settings', icon: Icons.settings_outlined),
    (route: '/purchase?type=bill', label: 'Purchases', icon: Icons.shopping_cart_outlined),
  ];

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
    // Warm the firm list while the dashboard is open: the switcher sheet
    // reads it on tap, and an unwatched FutureProvider is still loading at
    // that moment — the sheet opened EMPTY (the "company not showing" bug).
    ref.watch(allFirmsProvider);

    final now = DateTime.now();
    final from = DateTime(now.year, now.month, 1);
    final hour = now.hour;
    final greeting = hour < 12
        ? 'Good Morning'
        : hour < 17
        ? 'Good Afternoon'
        : 'Good Evening';

    // The greeting header carries two lines, and `toolbarHeight` is what gives
    // them room. It was a flat 72, which the default text size fits and a
    // 2.0× system font (see `app.dart`, which no longer caps text scaling)
    // does not — the pair is ~54dp at 1.0 and ~108 at 2.0, and a title taller
    // than the toolbar overflows it. Scaling the band with the type keeps the
    // headline legible instead of trading it away for a fixed height.
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final toolbarHeight = (72 * textScale).clamp(72.0, 144.0);

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
        child: LayoutBuilder(
          // QBO's dashboard is a two-column card grid on a desktop width and
          // one long column on a phone — but "desktop width" means the width of
          // the *pane*, not of the window. `AdaptiveNavShell` removes 236+1dp
          // for the extended rail at exactly the same `Breakpoints.medium`
          // threshold, so a window at 900dp used to take the two-column branch
          // with 663dp of real width and split it into ~375/250 columns. The
          // pane's own constraints are what this decision has to read — the
          // same reason `AtriaEditorForm` uses a `LayoutBuilder` here.
          builder: (context, constraints) => CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                stretch: true,
                toolbarHeight: toolbarHeight,
                titleSpacing: 0,
                // NOT `primary`, so no second status-bar inset.
                //
                // `SliverAppBar` is `primary: true` by default, which prepends
                // `MediaQuery.padding.top` to its own height and parks the
                // toolbar row that far down — leaving that much blank band
                // above the greeting. On a phone that band is a dead status-bar
                // height between the chrome and the content, and it grows with
                // a taller inset on a cutout or in landscape.
                //
                // It must be dropped *here* and not globally, because this
                // screen is not the only `SliverAppBar`. `AdaptiveNavShell`
                // stacks `AtriaTopBar` — which insets itself with `SafeArea` —
                // directly above the branch navigators, so everything below it
                // has already had the status bar drawn. But `_BottomShell`
                // drops the top bar entirely for detail routes
                // (`/detail/…`, `/edit/…`), and there `sale_detail_screen.dart`'s
                // `SliverAppBar` is the only thing that will ever inset for the
                // status bar — so that one keeps its default.
                primary: false,
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        firm?.name ?? 'Apex Books',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                actions: [
                  // The green Create button lives in the header, as it does in
                  // QBO — the page itself carries no create tiles.
                  const AtriaCreateButton(menuOffset: Offset(0, 46)),
                  const SizedBox(width: 10),
                  IconButton(
                    onPressed: () => _showFirmSwitcher(context),
                    icon: const Icon(Icons.business_center_outlined, size: 20),
                    tooltip: 'Switch business',
                  ),
                  IconButton(
                    // `go`, never `push` — see the class doc.
                    onPressed: () => context.go('/settings'),
                    icon: const Icon(PhosphorIconsRegular.gear, size: 20),
                    tooltip: 'Settings',
                  ),
                  const SizedBox(width: 12),
                ],
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    if (reports == null)
                      const _NoFirmState()
                    else ...[
                      // QuickBooks' dashboard order: the business
                      // snapshot, the movement figures, then profit &
                      // loss beside the invoices owed to you, and the
                      // get-things-done checklist last.
                      _HeroCard(firm: firm, reports: reports, from: from),
                      const SizedBox(height: 16),
                      // **The two tile grids, phone only.**
                      //
                      // The reference's home puts `Create` and `Quick Access`
                      // directly under the sales/purchases figure, and this is
                      // the one place the mobile dashboard is genuinely
                      // different from the desktop one rather than a reflow of
                      // it. Desktop has neither: its create actions live in the
                      // chrome and the rail, and a 1920px strip of eight icons
                      // is decoration. Each widget renders nothing off-mobile, so
                      // the desktop tree is unchanged by being named here.
                      if (Theme.of(context).platform.isMobileUi) ...[
                        const MobileCreateGrid(),
                        const SizedBox(height: 16),
                        MobileQuickAccessGrid(
                          entries: _quickAccess,
                        ),
                        const SizedBox(height: 20),
                      ],
                      _KpiGrid(reports: reports, from: from),
                      const SizedBox(height: 20),
                      if (constraints.maxWidth >= Breakpoints.medium)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 3,
                              child: _TrendSection(reports: reports),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 2,
                              child: Column(
                                children: [
                                  _RecentInvoices(),
                                  const SizedBox(height: 16),
                                  _AlertsSection(reports: reports),
                                ],
                              ),
                            ),
                          ],
                        )
                      else ...[
                        _TrendSection(reports: reports),
                        const SizedBox(height: 20),
                        _RecentInvoices(),
                        const SizedBox(height: 20),
                        _AlertsSection(reports: reports),
                      ],
                      const SizedBox(height: 20),
                      _QuickActions(),
                    ],
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFirmSwitcher(BuildContext context) {
    final activeId = ref.read(activeFirmIdProvider);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        // The sheet watches the provider itself: even if it was still loading
        // when the sheet opened, the list appears the moment it resolves
        // instead of leaving an empty sheet.
        return Consumer(
          builder: (sheetContext, sheetRef, _) {
            final firmsAsync = sheetRef.watch(allFirmsProvider);
            final firms = firmsAsync.valueOrNull ?? const [];
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 8, right: 8, bottom: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 16, bottom: 8),
                      child: Text(
                        // The reference's title, verbatim: "Select Business"
                        // says what the sheet does, where "Your businesses"
                        // describes what is in it.
                        'Select Business',
                        style: Theme.of(sheetContext).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (firmsAsync.isLoading && firms.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else if (firms.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No businesses yet.'),
                      )
                    else
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final f in firms)
                            _SelectBusinessRow(
                              firm: f,
                              selected: f.id == activeId,
                              // Only the row itself selects. Wrapping the whole
                              // row in a `Radio` would make "Edit Company" and
                              // "Share" taps switch business *and* push a page,
                              // which is the kind of thing that loses a form.
                              onSelect: () {
                                sheetRef
                                    .read(activeFirmIdProvider.notifier)
                                    .select(f.id);
                                sheetRef
                                    .read(firmRepositoryProvider)
                                    .setDefault(f.id);
                                Navigator.of(sheetContext).pop();
                              },
                              onEdit: () {
                                Navigator.of(sheetContext).pop();
                                context.push('/settings/firm');
                              },
                              onShare: () {
                                Navigator.of(sheetContext).pop();
                                context.push('/settings/firm');
                              },
                            ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    // **A centred text action, not a filled button.** The
                    // reference's is `+ Add new Business` in blue with no
                    // background — a full-width tonal button would claim to be
                    // the sheet's primary action, and it is not: the sheet's job
                    // is to change which business you are in, and this is a way
                    // out of it.
                    Center(
                      child: TextButton.icon(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          context.push('/onboarding/firm-setup');
                        },
                        icon: const Icon(Icons.add, size: 20),
                        label: const Text('Add new Business'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// One row of the **Select Business** sheet, as in the reference.
///
/// Avatar, name, GSTIN, `Edit Company` / `Share`, and a selected-radio at the
/// right. The radio is decorative here rather than the control: the whole row
/// selects, and a tap that has to find a 20dp target to do the obvious thing is
/// worse on a phone than one that works where you pressed.
class _SelectBusinessRow extends StatelessWidget {
  const _SelectBusinessRow({
    required this.firm,
    required this.selected,
    required this.onSelect,
    required this.onEdit,
    required this.onShare,
  });

  final FirmEntity firm;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final gstin = (firm.gstin ?? '').trim();
    return InkWell(
      onTap: onSelect,
      borderRadius: AppRadius.mdAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: scheme.primaryContainer,
              child: Text(
                // The initial, so two businesses whose names start the same are
                // told apart at a glance.
                firm.name.isEmpty ? '?' : firm.name[0].toUpperCase(),
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    firm.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    gstin.isEmpty ? 'Unregistered' : gstin.toUpperCase(),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  // **Only for an unregistered firm.** The reference prints a
                  // GSTIN line; a firm without one would otherwise have a
                  // blank row where everyone else has a registration, which
                  // reads as a rendering fault rather than a fact.
                  if (gstin.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _InlineAction(label: 'Edit Company', onTap: onEdit),
                        const SizedBox(width: 16),
                        _InlineAction(label: 'Share', onTap: onShare),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // The selected mark. A ring with a dot, rather than a Radio, so it
            // reads as a selection indicator and not as a fifth tappable control.
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  width: 2,
                  color: selected ? scheme.primary : scheme.outline,
                ),
              ),
              child: selected
                  ? Icon(Icons.circle, size: 12, color: scheme.primary)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// A blue text action inside a business row.
class _InlineAction extends StatelessWidget {
  const _InlineAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // A tap target of the text itself, as in the reference — but at least a
      // full 24dp tall so it is not a 14dp target on a phone.
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
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
      message:
          'Create your first business or start with sample data to '
          'explore Apex Books end to end.',
      actionLabel: 'Set up business',
      onAction: () => context.push('/onboarding/firm-setup'),
    );
  }
}

/// The brand hero: gradient card with the headline sales number and the
/// two balances that matter most to a business owner.
class _HeroCard extends ConsumerWidget {
  const _HeroCard({
    required this.firm,
    required this.reports,
    required this.from,
  });

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
                Icon(
                  PhosphorIconsRegular.warningCircle,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  'Could not load today’s numbers',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '$e',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
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
        // QuickBooks' "Business snapshot": a plain white panel with a bold
        // title, the headline figure in ink, and the balances on a hairline
        // rule — no gradient band, no decoration competing with the numbers.
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;

        return AtriaCard(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Business snapshot',
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    Formatters.monthYear(DateTime.now()),
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Total sales this month',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 2),
              Text(
                Formatters.money(summary.totalSales),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.displayMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${Formatters.count(summary.invoiceCount, 'invoice')} this month',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: scheme.outline),
              const SizedBox(height: 12),
              // The four numbers every Indian billing home carries, in one
              // strip: what customers owe, what you owe, what is actually in
              // hand, and what the shelf is worth.
              IntrinsicHeight(
                child: Row(
                  children: [
                    _heroStat(
                      context,
                      'To receive',
                      Formatters.moneyCompact(summary.receivable),
                      PhosphorIconsRegular.arrowDownLeft,
                    ),
                    _heroDivider(),
                    _heroStat(
                      context,
                      'To pay',
                      Formatters.moneyCompact(summary.payable),
                      PhosphorIconsRegular.arrowUpRight,
                    ),
                    _heroDivider(),
                    _heroStat(
                      context,
                      'Cash in hand',
                      // Lifetime receipts less payments. The month-to-date
                      // figures belong in the KPIs below; here they labelled
                      // a balance that was really a period net.
                      Formatters.moneyCompact(summary.cashIn - summary.cashOut),
                      PhosphorIconsRegular.wallet,
                    ),
                    _heroDivider(),
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

  Widget _heroDivider() => VerticalDivider(
    width: 16,
    color: Color(0x00000000),
    indent: 2,
    endIndent: 2,
  );

  Widget _heroStat(
    BuildContext context,
    String label,
    String value,
    IconData icon,
  ) {
    // Four stats share the panel's width, so the icon moves above the label
    // instead of beside it — side by side, "Cash in hand" truncated.
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
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
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.xl)),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}

final _dashboardProvider = FutureProvider.family<DashboardSummary, DateTime>((
  ref,
  from,
) async {
  final reports = ref.watch(reportRepositoryProvider);
  if (reports == null) {
    return DashboardSummary.empty();
  }
  return reports.dashboard(from: from, to: DateTime.now());
});

/// QBO's "Get things done" card: a short list of green action links, each of
/// which is a page in itself. QBO deliberately avoids tiles here — the whole
/// card is text, which is why it survives any width.
class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    const actions = <(IconData, String, String)>[
      (
        PhosphorIconsRegular.receipt,
        'Create invoice',
        '/sales/new?type=invoice',
      ),
      (
        PhosphorIconsRegular.fileText,
        'Send a quote',
        '/sales/new?type=quotation',
      ),
      (PhosphorIconsRegular.arrowsLeftRight, 'Record a payment', '/payments'),
      (
        PhosphorIconsRegular.shoppingCart,
        'Enter a bill',
        '/purchase/new?type=bill',
      ),
      (
        PhosphorIconsRegular.moneyWavy,
        'Add an expense',
        '/expenses/new?type=expense',
      ),
      (PhosphorIconsRegular.cube, 'Add a product or service', '/items/new'),
      (
        PhosphorIconsRegular.users,
        'Add a customer',
        '/parties/new?type=customer',
      ),
      // The chase-up list. `/payment-reminders` sits outside the shell on
      // purpose (like `/pos`), and it is in neither `NavDestinations.sections`
      // nor the global search panel — so before this the *only* way into it was
      // the "Overdue" alert card, which does not render at all on a shop with
      // nothing overdue. This card always renders, so the reminders list is
      // reachable whether or not anything is late.
      (
        PhosphorIconsRegular.bellRinging,
        'Payment reminders',
        '/payment-reminders',
      ),
    ];

    return AtriaCard(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Get things done',
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              for (final (icon, label, route) in actions)
                TextButton.icon(
                  onPressed: () {
                    // `/payments` is a branch root; everything else
                    // in this list is a deep link into a branch, or a route
                    // outside the shell. See [DashboardScreen].
                    if (route == '/payments') {
                      context.go(route);
                    } else {
                      context.push(route);
                    }
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.primary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  icon: Icon(icon, size: 18),
                  label: Text(label),
                ),
            ],
          ),
        ],
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
        child: Text(
          'Could not load summary: $e',
          style: TextStyle(color: scheme.error),
        ),
      ),
      data: (summary) {
        // Three tiles now, not four: "Net received" became "Cash in hand" in
        // the hero strip directly above, so the grid was repeating a figure.
        // IntrinsicHeight keeps the three equal without a fixed aspect ratio.
        //
        // The caption names the window: these three are month-to-date like the
        // hero above them, and unlabelled they read as lifetime totals — a
        // book with purchases recorded only in an earlier month showed
        // "Purchases ₹0.00" next to a non-zero GST figure.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 6),
              child: Text(
                'This month so far · since ${Formatters.date(from)}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _KpiCard(
                      label: 'Purchases',
                      amount: summary.totalPurchases,
                      icon: PhosphorIconsRegular.shoppingCart,
                      tint: colors.saffronGradientStart,
                      onTap: () => context.go('/purchase'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _KpiCard(
                      label: 'Expenses',
                      amount: summary.totalExpenses,
                      icon: PhosphorIconsRegular.moneyWavy,
                      tint: colors.negative,
                      onTap: () => context.go('/expenses'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _KpiCard(
                      label: 'GST payable',
                      amount: summary.gstPayable,
                      icon: PhosphorIconsRegular.receipt,
                      tint: colors.warning,
                      onTap: () => context.go('/reports'),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
            border: Border.all(color: Theme.of(context).colorScheme.outline),
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
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700, fontSize: 17),
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
          onAction: () => context.go('/reports'),
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
        child: Text(
          'Could not load trend: $e',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
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

final _trendProvider = FutureProvider.autoDispose<List<MonthlyPoint>>((
  ref,
) async {
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

  double get _maxValue {
    var max = 0.0;
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
          SizedBox(
            height: _TrendBars.height,
            child: LayoutBuilder(
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
                                // The bars cap at 16px but give way when the
                                // month group is narrower than that — on a
                                // 360dp screen six months share ~290px, so a
                                // group is ~48px and its 0.72 slot is 34px,
                                // less than the 36px two fixed bars need.
                                // Fixed-width bars overflowed by a fraction
                                // and painted the striped banner.
                                Flexible(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 16,
                                    ),
                                    child: _bar(
                                      context,
                                      height:
                                          _TrendBars.barHeight *
                                          (p.sales.toDouble() / max),
                                      color: colors.brandGradientStart,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 16,
                                    ),
                                    child: _bar(
                                      context,
                                      height:
                                          _TrendBars.barHeight *
                                          (p.purchases.toDouble() / max),
                                      color: colors.saffronGradientStart,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              Formatters.monthYear(p.month).substring(0, 3),
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
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
          ),
        ],
      ),
    );
  }

  Widget _bar(
    BuildContext context, {
    required double height,
    required Color color,
  }) {
    return Container(
      width: 16,
      height: height.clamp(2, double.infinity),
      decoration: BoxDecoration(
        color: color,
        // A bar rounds its top corners only, on the 4px scale.
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(AppRadius.xs),
          topRight: Radius.circular(AppRadius.xs),
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
            // 2px, not 3: a legend swatch reads as either a dot or the bar it
            // stands for, and 3px was neither.
            borderRadius: const BorderRadius.all(Radius.circular(AppRadius.xs)),
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
          onAction: () => context.go('/sales'),
        ),
        StreamBuilder(
          stream: invoices,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const AtriaCard(
                child: SizedBox(
                  height: 72,
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
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
                for (final invoice in data) _InvoiceTile(invoice: invoice),
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
              border: Border.all(color: Theme.of(context).colorScheme.outline),
              boxShadow: AppShadows.card,
            ),
            child: Row(
              children: [
                AtriaAvatar.initials(
                  name: invoice.partyName ?? 'Walk-in customer',
                  radius: AtriaAvatar.row,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        invoice.partyName ?? 'Walk-in customer',
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${invoice.number} • ${Formatters.date(invoice.invoiceDate)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                  colorize: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AlertsSection extends ConsumerWidget {
  const _AlertsSection({required this.reports});

  final ReportRepository reports;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final future = ref.watch(
      _dashboardProvider(
        DateTime(DateTime.now().year, DateTime.now().month, 1),
      ),
    );

    return future.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          children: [
            Icon(
              PhosphorIconsRegular.warningCircle,
              size: 16,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Could not load alerts — $e',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: () => ref.invalidate(
                _dashboardProvider(
                  DateTime(DateTime.now().year, DateTime.now().month, 1),
                ),
              ),
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
        final lowStock = summary.lowStockCount > 0
            ? _AlertCard(
                icon: PhosphorIconsRegular.package,
                tint: colors.warning,
                title: 'Low stock',
                body:
                    '${Formatters.count(summary.lowStockCount, 'item')} at or below the alert level',
                onTap: () => context.go('/stock'),
              )
            : null;
        final overdue = summary.overdueCount > 0
            ? _AlertCard(
                icon: PhosphorIconsRegular.warning,
                tint: colors.negative,
                title: 'Overdue',
                body:
                    '${Formatters.count(summary.overdueCount, 'invoice')} past the due date',
                // Straight to the reminders list — the action a user takes on
                // overdue invoices is nudging the party.
                onTap: () => context.push('/payment-reminders'),
              )
            : null;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(title: 'Needs attention'),
            // Stacked below `Breakpoints.medium` of *pane*. Two cards side by
            // side share whatever the pane gives them, and the shell has
            // already taken the rail — at 900dp of window that is ~330dp each,
            // and on a 360dp phone it is 156dp each, where both bodies wrap to
            // four or five lines. One under the other reads as a list and costs
            // the reader nothing.
            LayoutBuilder(
              builder: (context, constraints) {
                final cards = [
                  ?lowStock,
                  ?overdue,
                ];
                if (cards.length < 2 ||
                    constraints.maxWidth < Breakpoints.medium) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < cards.length; i++) ...[
                        if (i > 0) const SizedBox(height: 12),
                        cards[i],
                      ],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: cards[0]),
                    const SizedBox(width: 12),
                    Expanded(child: cards[1]),
                  ],
                );
              },
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
            border: Border.all(color: Theme.of(context).colorScheme.outline),
            boxShadow: AppShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: tint),
              const SizedBox(height: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700, color: tint),
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
