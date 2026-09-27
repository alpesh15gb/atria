import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/navigation/nav_destinations.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/theme/app_radius.dart';
import 'atria_logo.dart';

/// One shell that adapts: bottom bar on phones, side rail on tablets/desktop.
///
/// Used as the builder of a `StatefulShellRoute.indexedStack`. The shell's
/// [navigationShell] IS the widget tree that hosts every branch navigator —
/// list tabs *and* their nested routes (`/sales/new`, `/items/edit/:id`,
/// `/parties/new`, …). It must always be mounted, or those pushes render
/// nothing and every "new invoice / add item / add party" button appears dead.
class AdaptiveNavShell extends StatelessWidget {
  const AdaptiveNavShell({
    super.key,
    required this.navigationShell,
  });

  final StatefulNavigationShell navigationShell;

  /// The branch [navigationShell] is currently showing.
  int get _currentIndex => navigationShell.currentIndex;

  /// The index the bottom bar should highlight: secondary destinations
  /// (branch > primary.length) all fold onto the "More" slot.
  int get _bottomBarIndex =>
      _currentIndex <= NavDestinations.primary.length
          ? _currentIndex
          : NavDestinations.primary.length;

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

class _BottomShell extends StatelessWidget {
  const _BottomShell({
    required this.navigationShell,
    required this.bottomBarIndex,
    required this.onTap,
  });

  final StatefulNavigationShell navigationShell;
  final int bottomBarIndex;
  final ValueChanged<int> onTap;

  int get _currentIndex => navigationShell.currentIndex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // The shell carries the branch navigators — the list screens and
      // everything pushed on top of them.
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: bottomBarIndex,
        onDestinationSelected: (value) {
          if (value == NavDestinations.primary.length) {
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
            selectedIcon: Icon(
              Icons.more_horiz_rounded,
              color: scheme.primary,
            ),
            label: 'More',
          ),
        ],
      ),
    );
  }

  void _showMoreSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(
                left: 8, right: 8, top: 4, bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 12),
                  child: Text(
                    'More',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
                for (final d in NavDestinations.secondary)
                  ListTile(
                    leading: Icon(
                      d.icon,
                      color: NavDestinations.all.indexOf(d) == _currentIndex
                          ? scheme.primary
                          : null,
                    ),
                    title: Text(
                      d.label,
                      style: TextStyle(
                        fontWeight:
                            NavDestinations.all.indexOf(d) == _currentIndex
                                ? FontWeight.w700
                                : null,
                        color: NavDestinations.all.indexOf(d) == _currentIndex
                            ? scheme.primary
                            : null,
                      ),
                    ),
                    // The active destination is now visible in the sheet —
                    // it used to look like nothing was selected.
                    trailing:
                        NavDestinations.all.indexOf(d) == _currentIndex
                            ? Icon(Icons.check_rounded,
                                size: 18, color: scheme.primary)
                            : null,
                    shape: const RoundedRectangleBorder(
                        borderRadius: AppRadius.mdAll),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onTap(NavDestinations.all.indexOf(d));
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RailShell extends StatelessWidget {
  const _RailShell({
    required this.navigationShell,
    required this.extended,
  });

  final StatefulNavigationShell navigationShell;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          // Both rails are hand-rolled instead of using [NavigationRail]: its
          // internal Expanded spacer cannot sit inside a scroll view, and nine
          // destinations do not fit every window height. Scrolling beats
          // overflowing (and throwing) on short windows.
          if (extended)
            _ExtendedRail(navigationShell: navigationShell)
          else
            _CompactRail(navigationShell: navigationShell),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: scheme.outline,
          ),
          Expanded(child: navigationShell),
        ],
      ),
    );
  }
}

/// Shared scaffolding for both rail variants: a fixed-width column holding the
/// logo and every destination, scrollable when the window is too short.
class _RailColumn extends StatelessWidget {
  const _RailColumn({
    required this.width,
    required this.logoSize,
    required this.children,
  });

  final double width;
  final double logoSize;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 12),
              child: Center(child: AtriaLogo(size: logoSize)),
            ),
            ...children,
            // Breathing room at the end so the last destination is not glued
            // to the window edge when the list does fit.
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Icon-over-label rail button for the collapsed rail.
class _CompactRailButton extends StatelessWidget {
  const _CompactRailButton({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final NavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 21,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 4),
                Text(
                  destination.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500,
                    color:
                        selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactRail extends StatelessWidget {
  const _CompactRail({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final currentIndex = navigationShell.currentIndex;
    return _RailColumn(
      width: 84,
      logoSize: 34,
      children: [
        for (var i = 0; i < NavDestinations.all.length; i++)
          _CompactRailButton(
            destination: NavDestinations.all[i],
            selected: i == currentIndex,
            onTap: () => navigationShell.goBranch(
              i,
              initialLocation: i == currentIndex,
            ),
          ),
      ],
    );
  }
}

class _ExtendedRail extends StatelessWidget {
  const _ExtendedRail({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final currentIndex = navigationShell.currentIndex;

    return _RailColumn(
      width: 232,
      logoSize: 36,
      children: [
        for (var i = 0; i < NavDestinations.all.length; i++) ...[
          if (i == NavDestinations.primary.length) ...[
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 14, bottom: 6),
              child: Text(
                'BUSINESS',
                style: text.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          _RailButton(
            destination: NavDestinations.all[i],
            selected: i == currentIndex,
            onTap: () => navigationShell.goBranch(
              i,
              initialLocation: i == currentIndex,
            ),
          ),
        ],
      ],
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final NavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 20,
                  color: selected
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    destination.label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                      color:
                          selected ? scheme.primary : scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
