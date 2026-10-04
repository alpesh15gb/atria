import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/navigation/nav_destinations.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import 'atria_create_menu.dart';
import 'atria_top_bar.dart';

/// One shell that adapts: bottom bar on phones, side rail on tablets/desktop.
///
/// Used as the builder of a `StatefulShellRoute.indexedStack`. The shell's
/// [navigationShell] IS the widget tree that hosts every branch navigator —
/// list tabs *and* their nested routes (`/sales/new`, `/items/edit/:id`,
/// `/parties/new`, …). It must always be mounted, or those pushes render
/// nothing and every "new invoice / add item / add party" button appears dead.
class AdaptiveNavShell extends StatelessWidget {
  const AdaptiveNavShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  int get _currentIndex => navigationShell.currentIndex;

  /// The index the bottom bar should highlight: secondary destinations
  /// (branch >= bottomBarItemCount) all fold onto the "More" slot.
  int get _bottomBarIndex => _currentIndex < NavDestinations.bottomBarItemCount
      ? _currentIndex
      : NavDestinations.bottomBarItemCount;

  void _goBranch(int index) {
    navigationShell.goBranch(
      index,
      // Tapping the branch you are already in pops it back to its root —
      // the standard Android bottom-bar contract.
      initialLocation: index == _currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder (not MediaQuery) so the shell reacts to the space it is
    // actually given — consistent with every other breakpoint in the app.
    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= Breakpoints.compact;
        if (useRail) {
          return _RailShell(
            navigationShell: navigationShell,
            extended: constraints.maxWidth >= Breakpoints.medium,
          );
        }
        return _BottomShell(
          navigationShell: navigationShell,
          bottomBarIndex: _bottomBarIndex,
          onTap: _goBranch,
        );
      },
    );
  }
}

/// True when [entry] is the page currently on screen.
///
/// Matching is done on the *location*, not on the shell's branch index: most
/// Sales rows are the same branch reached through a different `?type=`, so
/// only the query string can tell "Invoices" from "Credit notes".
///
/// The MOST SPECIFIC entry wins. `/settings/firm` is the Company profile and
/// not also Settings; `/ledger/trial-balance` is the Trial balance and not also
/// the Chart of accounts the branch is rooted at. Only when no entry names the
/// page itself does the deepest branch root that is an ancestor of it stay lit —
/// which is what keeps "Sales" marked while an invoice is open at
/// `/sales/detail/5`.
bool navEntryIsActive(Uri location, NavSectionEntry entry) {
  final all = <NavSectionEntry>[
    for (final section in NavDestinations.sections) ...section.entries,
  ];

  bool namesThePageExactly(NavSectionEntry candidate) {
    final path = candidate.route.split('?').first;
    if (location.path != path) return false;
    if (!candidate.route.contains('?')) return true;
    final wanted = Uri.splitQueryString(candidate.route.split('?')[1]);
    for (final key in wanted.keys) {
      if (location.queryParameters[key] != wanted[key]) return false;
    }
    return true;
  }

  // Two entries can share a route (that was a bug in its own right, but the
  // data allows it), so match on route equality rather than object identity —
  // otherwise a duplicated row would light up and its twin would not.
  for (final candidate in all) {
    if (namesThePageExactly(candidate) && candidate.route == entry.route) {
      return true;
    }
  }
  if (all.any(namesThePageExactly)) return false;

  // Nothing names this page: fall back to the deepest ancestor.
  NavSectionEntry? best;
  for (final candidate in all) {
    final path = candidate.route.split('?').first;
    if (!location.path.startsWith('$path/')) continue;
    if (best == null ||
        path.length > best.route.split('?').first.length) {
      best = candidate;
    }
  }
  return best != null && best.route == entry.route;
}

class _BottomShell extends StatelessWidget {
  const _BottomShell({
    required this.navigationShell,
    required this.bottomBarIndex,
    required this.onTap,
  });

  final StatefulNavigationShell navigationShell;
  final int bottomBarIndex;
  final ValueChanged<int> onTap;

  static bool _isEditorOrDetailRoute(String path) {
    if (path.endsWith('/new')) return true;
    if (path.contains('/edit/')) return true;
    if (path.contains('/detail/')) return true;
    // The account ledger is a pushed, full-screen reading route like every
    // other detail page, but its path matches none of the patterns above, so it
    // kept the top bar and the bottom navigation while its siblings dropped
    // both.
    if (path.startsWith('/ledger/account/')) return true;
    if (path.contains('/statement/')) return true;
    if (path == '/purchase/scan') return true;
    if (path.startsWith('/settings/') && path != '/settings') return true;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    String? path;
    try {
      path = GoRouterState.of(context).uri.path;
    } catch (_) {
      path = null;
    }

    if (path != null && _isEditorOrDetailRoute(path)) {
      return navigationShell;
    }

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // The chrome band sits above the branch navigators, exactly as QBO keeps
      // its top bar above everything: the business you are in, search and the
      // account controls must not scroll away with the page.
      body: Column(
        children: [
          const AtriaTopBar(),
          // The shell carries the branch navigators — the list screens and
          // everything pushed on top of them.
          Expanded(child: navigationShell),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        selectedIndex: bottomBarIndex,
        onDestinationSelected: (value) {
          if (value == NavDestinations.bottomBarItemCount) {
            _showMoreSheet(context);
            return;
          }
          onTap(value);
        },
        destinations: [
          for (final d in NavDestinations.primary)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
          NavigationDestination(
            icon: Icon(
              Icons.more_horiz_rounded,
              color: scheme.onSurfaceVariant,
            ),
            selectedIcon: Icon(Icons.more_horiz_rounded, color: scheme.primary),
            label: 'More',
          ),
        ],
      ),
    );
  }

  /// The quiet all-caps section heading QuickBooks uses in its own menu —
  /// and the same one the desktop rail paints.
  Widget _sectionLabel(BuildContext context, String label) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 12, bottom: 2),
      child: Text(
        label,
        style: text.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  void _showMoreSheet(BuildContext context) {
    // The location must be read HERE, in the shell's context: a modal sheet's
    // builder context sits above the root navigator's overlay, where
    // GoRouterState is not provided — reading it in the builder threw on
    // Android and rendered the More sheet as a blank white screen.
    final location = GoRouterState.of(context).uri;
    final shellContext = context;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.only(
                left: 8,
                right: 8,
                top: 4,
                bottom: 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 8),
                    child: AtriaCreateButton(
                      menuOffset: const Offset(0, 8),
                      // Close the sheet before the chosen screen lands,
                      // or it stays open underneath the new route.
                      onAfterSelect: () => Navigator.of(sheetContext).pop(),
                    ),
                  ),
                  // Every section the rail shows, minus the rows already on
                  // the bottom bar — same grouping, same order, so the two
                  // navigations never teach different maps.
                  for (final section in NavDestinations.sections) ...[
                    Builder(
                      builder: (context) {
                        final entries = section.entries
                            .where(
                              (e) =>
                                  e.branchIndex == null ||
                                  e.branchIndex! >=
                                      NavDestinations.bottomBarItemCount,
                            )
                            .toList();
                        if (entries.isEmpty) return const SizedBox.shrink();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _sectionLabel(sheetContext, section.title),
                            for (final entry in entries)
                              ListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                leading: Icon(
                                  entry.icon,
                                  size: 18,
                                  color: navEntryIsActive(location, entry)
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                                title: Text(
                                  entry.label,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: navEntryIsActive(
                                      location,
                                      entry,
                                    )
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: navEntryIsActive(location, entry)
                                        ? scheme.primary
                                        : null,
                                  ),
                                ),
                                trailing: navEntryIsActive(location, entry)
                                    ? Icon(
                                        Icons.check_rounded,
                                        size: 18,
                                        color: scheme.primary,
                                      )
                                    : null,
                                shape: const RoundedRectangleBorder(
                                  borderRadius: AppRadius.smAll,
                                ),
                                onTap: () {
                                  Navigator.of(sheetContext).pop();
                                  // From the SHELL's context: the sheet's tiles
                                  // unmount with the sheet, and navigating from
                                  // a deactivated element is the same crash
                                  // class as reading state there. `go`, never
                                  // `push` — see _CompactRail.
                                  shellContext.go(entry.route);
                                },
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RailShell extends StatelessWidget {
  const _RailShell({required this.navigationShell, required this.extended});

  final StatefulNavigationShell navigationShell;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          // The wordmark lives up here, aligned with the nav column below it —
          // QBO's arrangement. That is why the rail itself starts at Create.
          AtriaTopBar(leadingWidth: extended ? 236 : 64, compactLeading: !extended),
          Expanded(
            child: Row(
              children: [
                // Both rails are hand-rolled instead of using [NavigationRail]:
                // its internal Expanded spacer cannot sit inside a scroll view,
                // and the QBO section stack is long. Scrolling beats
                // overflowing (and throwing) on short windows.
                if (extended)
                  _ExtendedRail(navigationShell: navigationShell)
                else
                  _CompactRail(navigationShell: navigationShell),
                Container(width: 1, color: scheme.outline),
                Expanded(child: navigationShell),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared scaffolding for both rail variants: a fixed-width column holding the
/// wordmark, the Create button and the section stack, scrollable when the
/// window is too short.
class _RailColumn extends StatelessWidget {
  const _RailColumn({
    required this.width,
    required this.header,
    required this.children,
  });

  final double width;
  final Widget header;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: ColoredBox(
        color: scheme.surface,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              ...children,
              // Breathing room at the end so the last destination is not glued
              // to the window edge when the list does fit.
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// Section heading in the rail: `SALES`, `EXPENSES`, … — the label QuickBooks
/// prints above each group.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, this.top = 14});

  final String title;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 16, top: top, bottom: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

/// A destination row: glyph, label, and — when selected — the brand's tinted
/// strip, the way QBO marks the page you are on.
class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.entry,
    required this.selected,
    required this.onTap,
    this.showLabel = true,
  });

  final NavSectionEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.sm);
    final fg = selected ? scheme.primary : scheme.onSurface;

    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Stack(
            children: [
              if (selected)
                Positioned(
                  left: 0,
                  top: 5,
                  bottom: 5,
                  child: Container(
                    // A 3px bar is a deliberate hairline, but its corner was a
                    // literal 2 — off the radius scale, and visually identical
                    // to the pill the app already uses for a full-round bar.
                    width: 3,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: const BorderRadius.all(
                        Radius.circular(AppRadius.pill),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  showLabel ? AppSpace.lg : 0,
                  AppSpace.sm,
                  AppSpace.md,
                  AppSpace.sm,
                ),
                child: Row(
                  mainAxisAlignment: showLabel
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: [
                    Icon(entry.icon, size: 18, color: fg),
                    if (showLabel) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: fg,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 44dp is the minimum comfortable target; the natural height of this row is
    // about 38, which is under it in BOTH rails.
    row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: row,
    );

    if (showLabel) return row;

    // The icon rail renders 32 destinations in a 64dp column with no room for
    // words, so the label has to survive somewhere: a tooltip for the pointer
    // and a semantic label for a screen reader. Without them a dozen
    // near-identical glyphs (`scales` for Trial balance, `books` for Balance
    // sheet, `clipboardText` twice for Sales orders and GST returns) are
    // unidentifiable. `excludeSemantics` stops the bare icon announcing as an
    // unlabelled image alongside the row's own label.
    return Semantics(
      button: true,
      selected: selected,
      label: entry.label,
      excludeSemantics: true,
      child: Tooltip(message: entry.label, child: row),
    );
  }
}

/// Icon-only rail used between the phone and desktop breakpoints.
class _CompactRail extends StatelessWidget {
  const _CompactRail({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final location = GoRouterState.of(context).uri;
    return _RailColumn(
      width: 64,
      header: const Padding(
        padding: EdgeInsets.only(top: 10, bottom: 10),
        child: Column(
          children: [
            AtriaCreateButton(expanded: false),
          ],
        ),
      ),
      children: [
        Container(
          height: 1,
          margin: const EdgeInsets.symmetric(horizontal: 10),
          color: scheme.outline,
        ),
        const SizedBox(height: 8),
        for (final section in NavDestinations.sections)
          for (final entry in section.entries)
            _SectionRow(
              entry: entry,
              selected: navEntryIsActive(location, entry),
              showLabel: false,
              onTap: () {
                // `go`, never `push`. Every one of these routes lives INSIDE a
                // StatefulShellBranch, and go_router resolves an imperative push
                // of a branch route by appending an ImperativeRouteMatch to the
                // shell's own match list — which puts a second, shell-less copy
                // of the route on the ROOT navigator. The page then renders
                // full-screen with no rail and no bottom bar, and Android Back
                // unwinds to the previous page instead of behaving like a tab.
                // `go` replaces the match list outright, so the shell stays a
                // single instance and the branch switches properly — and it
                // carries the `?type=` query these destinations depend on, which
                // `goBranch` cannot express.
                context.go(entry.route);
              },
            ),
      ],
    );
  }
}

/// The full rail: wordmark, Create button, then QBO's section stack.
class _ExtendedRail extends StatelessWidget {
  const _ExtendedRail({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final location = GoRouterState.of(context).uri;
    return _RailColumn(
      width: 236,
      header: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // No wordmark here any more: it moved into the top bar above, so
            // the pane opens with QBO's green Create button instead.
            const AtriaCreateButton(),
            const SizedBox(height: 6),
          ],
        ),
      ),
      children: [
        Container(height: 1, color: scheme.outline),
        for (var s = 0; s < NavDestinations.sections.length; s++) ...[
          _SectionHeading(
            title: NavDestinations.sections[s].title,
            // The first heading follows a rule, so it needs no extra air.
            top: s == 0 ? 10 : 14,
          ),
          for (final entry in NavDestinations.sections[s].entries)
            _SectionRow(
              entry: entry,
              selected: navEntryIsActive(location, entry),
              onTap: () {
                // `go`, never `push` — see _CompactRail.
                context.go(entry.route);
              },
            ),
        ],
        // The rail footer: QBO keeps its branding at the bottom of the pane.
        const SizedBox(height: 8),
        Divider(height: 1, color: scheme.outline),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              Icon(
                PhosphorIconsRegular.checkCircle,
                size: 14,
                color: scheme.primary,
              ),
              const SizedBox(width: 6),
              // Expanded: this line is long enough to overflow the 236px rail
              // (the widget test caught the striped RenderFlex).
              Expanded(
                child: Text(
                  'Your books stay on this device',
                  maxLines: 2,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 0,
                      ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
