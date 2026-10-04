import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/navigation/nav_destinations.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/shared/widgets/adaptive_nav_shell.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    // Every route a rail row names has to EXIST, or `go` lands on the error
    // page, the shell unmounts with it, and the next row's label is simply not
    // in the tree. Production registers `/ledger/journals`, `/ledger/trial-
    // balance` and `/ledger/balance-sheet`; the original stub only had each
    // branch root plus a `new` child, so three real rail rows had nothing to
    // navigate to. Derived from the nav table so it cannot drift again.
    final extraByBranch = <String, List<String>>{};
    for (final section in NavDestinations.sections) {
      for (final entry in section.entries) {
        final q = entry.route.indexOf('?');
        final path = q == -1 ? entry.route : entry.route.substring(0, q);
        for (final d in NavDestinations.all) {
          if (path == d.routePath) continue;
          if (path.startsWith('${d.routePath}/')) {
            final sub = path.substring(d.routePath.length + 1);
            (extraByBranch[d.routePath] ??= <String>[]).add(sub);
          }
        }
      }
    }

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
                    for (final sub
                        in (extraByBranch[d.routePath] ?? const <String>[]))
                      GoRoute(
                        path: sub,
                        builder: (context, state) => _StubScreen(
                          key: Key('${d.routePath}/$sub'),
                          title: 'SCR:${d.routePath}/$sub',
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
    // The shell now renders the application chrome (wordmark, business
    // switcher, search), which reads the active firm — so it needs a
    // container, exactly as the app root provides one.
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final router = productionShapedRouter();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
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

    // Unmount first so drift's stream-teardown timers fire inside this test's
    // fake async; >=1s steps after dispose, or db.close() hangs (see STATE.md).
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  });

  testWidgets(
      'every rail row opens the branch it names',
      (tester) async {
    // A desktop-sized surface so the *extended* rail renders: it is the only
    // rail variant that prints labels, and QuickBooks' grouped sections (SALES,
    // EXPENSES, …) only exist there. Below Breakpoints.medium the rail is
    // icon-only by design.
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final router = productionShapedRouter();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // Rows are addressed by their OWN route, not merely by "the branch they
    // belong to". A row that names a branch root (`/stock`, `/reports`,
    // `/settings`) lands on it; a row that is a step inside a branch
    // (`/ledger/journals`) now lands on ITSELF instead of dropping the person
    // on the branch root — tapping "Journal entries" and being given the chart
    // of accounts was the old behaviour and it was wrong.
    //
    // The rail navigates with `go`, never `push`. An imperative push of a route
    // inside a StatefulShellBranch makes go_router append an
    // ImperativeRouteMatch beside the shell match, which hosts the page on the
    // ROOT navigator: the rail and bottom bar disappear and Back unwinds to
    // the previous page instead of behaving like a tab.
    final branchRows = [
      for (final section in NavDestinations.sections)
        for (final entry in section.entries)
          if (entry.branchIndex != null && entry.branchIndex != 0) entry,
    ];
    expect(branchRows, isNotEmpty);

    for (final entry in branchRows) {
      final path = entry.route.split('?').first;
      final target = NavDestinations.all[entry.branchIndex!];
      await tester.ensureVisible(find.text(entry.label).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.label).last);
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        path,
        reason: 'tapping "${entry.label}" must open $path',
      );
      // Only meaningful when the row IS the branch root: a row deeper than the
      // root must not be expected to paint the root's screen.
      if (path == target.routePath) {
        expect(find.byKey(Key('$path-root')), findsOneWidget,
            reason: 'tapping "${entry.label}" must show its branch screen');
      }
    }

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  });

  testWidgets(
      'mobile bottom shell hides navigation bar on editor sub-routes',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final router = productionShapedRouter();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // On branch root, NavigationBar is present
    expect(find.byType(NavigationBar), findsOneWidget);

    // Navigate to editor subroute /sales/new
    router.go('/sales/new');
    await tester.pumpAndSettle();

    // Editor is visible, but NavigationBar is hidden to prevent double bars on mobile
    expect(find.byKey(const Key('/sales-new')), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    // Returning to branch root restores the NavigationBar
    router.go('/sales');
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
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
