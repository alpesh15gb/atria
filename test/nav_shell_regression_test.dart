import 'package:atria/core/navigation/nav_destinations.dart';
import 'package:atria/shared/widgets/adaptive_nav_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Regression cover for the bug where "New Invoice", "Add Item", "Add Party"
/// and the purchase/expense buttons "did nothing": [AdaptiveNavShell] received
/// the go_router `StatefulNavigationShell` but never mounted it, building the
/// const list screens directly instead. The branch navigators — the trees that
/// host `/sales/new`, `/items/new`, `/parties/new`, `/purchase/new` and every
/// detail route — existed in the router but were never on screen, so every
/// editor push rendered nothing at all.
///
/// These tests build a real `StatefulShellRoute.indexedStack` around
/// [AdaptiveNavShell] with stub branch screens, then assert that pushed
/// sub-routes land in the visible tree and that the rail's tap→branch mapping
/// matches [NavDestinations] — the wiring the old shell never exercised.
void main() {
  /// A router shaped like the production one: one branch per
  /// [NavDestinations.all] entry, each with a stub root and a stub `new`
  /// sub-route, so rail indexes and pushed routes map exactly as they do in
  /// `app_router.dart`.
  GoRouter productionShapedRouter() {
    return GoRouter(
      initialLocation: '/dashboard',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, navigationShell) =>
              AdaptiveNavShell(navigationShell: navigationShell),
          branches: [
            for (final d in NavDestinations.all)
              StatefulShellBranch(routes: [
                GoRoute(
                  path: d.routePath,
                  builder: (context, state) => _StubScreen(
                    key: Key('${d.routePath}-root'),
                    title: 'SCR:${d.routePath}',
                  ),
                  routes: [
                    GoRoute(
                      path: 'new',
                      builder: (context, state) => _StubScreen(
                        key: Key('${d.routePath}-new'),
                        title: 'SCR:${d.routePath}/new',
                      ),
                    ),
                  ],
                ),
              ]),
          ],
        ),
      ],
    );
  }

  testWidgets(
      'pushed sub-routes render inside the shell (editors were invisible before)',
      (tester) async {
    final router = productionShapedRouter();

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // The shell is mounted and shows the branch root.
    expect(find.byType(AdaptiveNavShell), findsOneWidget);
    expect(find.byKey(const Key('/dashboard-root')), findsOneWidget);

    // The exact gesture the dead buttons performed: context.push into the
    // branch. Before the fix this changed the router's URL while rendering
    // nothing, because the branch navigator hosting the pushed route was
    // never built into the tree.
    final context = tester.element(find.byKey(const Key('/dashboard-root')));
    context.push('/sales/new?type=invoice');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('/sales-new')), findsOneWidget,
        reason: 'a pushed sub-route must be visible inside the shell');

    // Back returns to the branch root, still inside the same shell.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('/dashboard-root')), findsOneWidget);

    // Editor routes of other branches render too — the party editor that the
    // dashboard's "Add Party" opens.
    router.go('/parties/new');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('/parties-new')), findsOneWidget);

    // And the purchase + expenses routes the KPI cards open.
    router.go('/purchase/new');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('/purchase-new')), findsOneWidget);

    router.go('/expenses/new');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('/expenses-new')), findsOneWidget);
  });

  testWidgets(
      'rail taps map NavDestinations order onto the matching branch and screen',
      (tester) async {
    final router = productionShapedRouter();

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // Rail layout: the 800x600 test surface is above Breakpoints.compact but
    // below Breakpoints.medium, so the collapsed rail shows. The rail column
    // scrolls on short windows (ten destinations don't fit 600px), so each
    // entry is scrolled into view before tapping — the off-screen taps
    // silently missed and the test just re-asserted the previous branch.
    for (final d in NavDestinations.all.skip(1)) {
      await tester.ensureVisible(find.text(d.label).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(d.label).last);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, d.routePath,
          reason: 'tapping "${d.label}" must open ${d.routePath}');
      expect(find.byKey(Key('${d.routePath}-root')), findsOneWidget,
          reason: 'tapping "${d.label}" must show its branch screen');
    }
  });
}

class _StubScreen extends StatelessWidget {
  const _StubScreen({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: Text(title)), body: const SizedBox());
  }
}
