import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/pos/pos_screen.dart';
import 'package:atria/features/sales/payment_reminders_screen.dart';
import 'package:atria/features/sales/sales_list_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A screen outside the nav shell must offer its own way out.
///
/// `/pos` and `/payment-reminders` are root-level routes on purpose — the
/// counter screen takes the whole window, and a rail would only be something to
/// scroll past between customers. That decision removes the two things a shell
/// screen gets for free: the rail, and a navigator that can pop.
///
/// The rail reaches both with `go`, which *replaces* the match list rather than
/// pushing onto it. The root navigator is then left holding a single page,
/// `Navigator.canPop()` is false, and `AppBar`'s `automaticallyImplyLeading`
/// back button silently never renders. Both screens were reachable and
/// completely inescapable — on the POS, that means mid-customer with a cart on
/// screen and only the window close button to go with it.
///
/// The rule these tests pin down: every shell-less route carries an exit, and
/// the exit lands somewhere real.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Mirrors `app_router.dart`'s shape: the two shell-less routes declared
  /// before the `StatefulShellRoute`, and one shell branch to arrive from.
  GoRouter buildRouter() => GoRouter(
        initialLocation: '/sales?type=invoice',
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (context, state) =>
                const Scaffold(body: Center(child: Text('DASHBOARD'))),
          ),
          GoRoute(
            path: '/payment-reminders',
            builder: (context, state) => const PaymentRemindersScreen(),
          ),
          GoRoute(
            path: PosScreen.routePath,
            builder: (context, state) => const PosScreen(),
          ),
          StatefulShellRoute.indexedStack(
            builder: (context, state, shell) => Scaffold(body: shell),
            branches: [
              StatefulShellBranch(routes: [
                GoRoute(
                  path: '/sales',
                  builder: (context, state) => SalesListScreen(
                    initialType: state.uri.queryParameters['type'],
                  ),
                ),
              ]),
            ],
          ),
        ],
      );

  Future<GoRouter> pumpApp(WidgetTester tester) async {
    final router = buildRouter();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return router;
  }

  /// Unmount, then let drift's zero-duration `markAsClosed` timers fire — they
  /// can only run while the test body still holds `FakeAsync`.
  Future<void> teardown(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> go(WidgetTester tester, GoRouter router, String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  testWidgets('the counter sale screen offers a way out, and it works',
      (tester) async {
    final router = await pumpApp(tester);

    // Arrived exactly the way the rail arrives: `go`, not `push`.
    await go(tester, router, '/pos');

    // The precondition that made this a bug — nothing to pop, so AppBar drew no
    // back button of its own accord.
    expect(
      find.byType(BackButton),
      findsNothing,
      reason: 'precondition: go() left no history, so AppBar implies no back',
    );

    final exit = find.byTooltip('Leave the counter');
    expect(
      exit,
      findsOneWidget,
      reason: 'a shell-less screen with no rail must own its exit',
    );

    await tester.tap(exit);
    await tester.pumpAndSettle();

    expect(find.text('DASHBOARD'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('payment reminders offers a way out, and it works',
      (tester) async {
    final router = await pumpApp(tester);

    await go(tester, router, '/payment-reminders');

    expect(find.byType(BackButton), findsNothing);

    final exit = find.byTooltip('Back');
    expect(
      exit,
      findsOneWidget,
      reason: 'payment reminders sits outside the shell too, and needs the same',
    );

    await tester.tap(exit);
    await tester.pumpAndSettle();

    expect(find.text('DASHBOARD'), findsOneWidget);
    await teardown(tester);
  });
}
