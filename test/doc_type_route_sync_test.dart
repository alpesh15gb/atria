import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/parties/parties_screen.dart';
import 'package:atria/features/purchase/purchase_list_screen.dart';
import 'package:atria/features/sales/sales_list_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A list screen must show the document type **the route is pointing at now**,
/// not the one it happened to be built with.
///
/// The bug: `SalesListScreen`, `PurchaseListScreen` and `PartiesScreen` each
/// read `?type=` once into a `late` field. `StatefulShellRoute.indexedStack`
/// keeps each branch's navigator alive, so `/sales?type=invoice` →
/// `/sales?type=quotation` resolves to the *same* `State` — the field was never
/// rewritten. Whichever type the rail was opened on first therefore won for the
/// whole session: click "Quotations" after having opened "Invoice" and the
/// heading, the filter pills and the green action button all still said
/// "invoice". Restarting the app was the only way to clear it.
///
/// `document_type_labels_test.dart` cannot catch this — it pumps a fresh screen
/// per case, so each one gets a brand-new State and the latched field is always
/// correct. These tests hold the tree still and move the route instead, which is
/// what the shell actually does.
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
    // Container first, then the database, both outside `FakeAsync`. Doing either
    // inside the test body trips the other: disposing the container while
    // `ActiveFirmController` still has futures in flight throws "Tried to use
    // ActiveFirmController after `dispose` was called", and closing the database
    // first leaves that same controller reaching for a closed connection ("Can't
    // re-open a database after closing it").
    container.dispose();
    await db.close();
  });

  /// Unmount, dispose the container, then advance fake time — the order
  /// `list_ux_regression_test.dart` established.
  ///
  /// This has to run inside the test body, not in `tearDown`: once the body
  /// returns, `FakeAsync` is gone, and drift's zero-duration `markAsClosed`
  /// timers — created as the watches unsubscribe — can never fire. Every case
  /// then ends on "A Timer is still pending even after the widget tree was
  /// disposed", which has nothing to do with the labels but fails the test all
  /// the same.
  /// Unmount the tree, then let drift's zero-duration `markAsClosed` timers
  /// fire.
  ///
  /// It has to happen inside the test body: once the body returns, `FakeAsync`
  /// is gone and those timers can never run, so every case would end on "A
  /// Timer is still pending even after the widget tree was disposed". The
  /// container and the database are left to `tearDown`.
  Future<void> teardown(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// The production shell shape, reduced to the three branches that carry a
  /// `?type=`. A plain `MaterialApp` would not reproduce the bug — the IndexedStack
  /// branch reuse is the whole mechanism.
  GoRouter buildRouter() => GoRouter(
        initialLocation: '/sales?type=invoice',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (context, state, shell) =>
                Scaffold(body: shell),
            branches: [
              StatefulShellBranch(routes: [
                GoRoute(
                  path: '/sales',
                  builder: (context, state) => SalesListScreen(
                    initialType: state.uri.queryParameters['type'],
                  ),
                ),
              ]),
              StatefulShellBranch(routes: [
                GoRoute(
                  path: '/purchase',
                  builder: (context, state) => PurchaseListScreen(
                    initialType: state.uri.queryParameters['type'],
                  ),
                ),
              ]),
              StatefulShellBranch(routes: [
                GoRoute(
                  path: '/parties',
                  builder: (context, state) => PartiesScreen(
                    initialType: state.uri.queryParameters['type'],
                  ),
                ),
              ]),
            ],
          ),
        ],
      );

  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    String location = '/sales?type=invoice',
  }) async {
    final router = buildRouter();
    router.go(location);
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

  Future<void> go(WidgetTester tester, GoRouter router, String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'sales: opening Quotations after Invoice shows Quotations, not a stuck '
      '"invoice"', (tester) async {
    final router = await pumpApp(tester);
    expect(find.text('New invoice'), findsWidgets);

    await go(tester, router, '/sales?type=quotation');

    expect(find.text('New quotation'), findsWidgets);
    expect(find.text('Quotations'), findsWidgets);
    // The headline symptom: the previous type must be gone from the page, not
    // merely accompanied by the new one.
    expect(
      find.text('New invoice'),
      findsNothing,
      reason: 'the type latched at first build must not survive a route change',
    );
    await teardown(tester);
  });

  testWidgets('sales: the reverse order is equally stuck-prone', (tester) async {
    final router = await pumpApp(tester, location: '/sales?type=credit_note');
    expect(find.text('New credit note'), findsWidgets);

    await go(tester, router, '/sales?type=invoice');

    expect(find.text('New invoice'), findsWidgets);
    expect(find.text('New credit note'), findsNothing);
    expect(find.text('Invoices'), findsWidgets);
    await teardown(tester);
  });

  testWidgets('sales: every type can be reached from any other', (tester) async {
    const expected = <String, String>{
      'invoice': 'New invoice',
      'quotation': 'New quotation',
      'sales_order': 'New sales order',
      'delivery_note': 'New delivery note',
      'credit_note': 'New credit note',
    };

    final router = await pumpApp(tester);
    // Walk the types in one session without ever tearing the tree down — the
    // order the user happened to click them in must not matter.
    for (final entry in expected.entries) {
      await go(tester, router, '/sales?type=${entry.key}');
      expect(
        find.text(entry.value),
        findsWidgets,
        reason: 'after landing on ${entry.key} the action must say '
            '"${entry.value}"',
      );
    }
    await teardown(tester);
  });

  testWidgets('purchase: the type follows the route across bills, orders and '
      'returns', (tester) async {
    const expected = <String, String>{
      'bill': 'Add bill',
      'purchase_order': 'New purchase order',
      'debit_note': 'New debit note',
    };

    final router = await pumpApp(tester, location: '/purchase?type=bill');
    for (final entry in expected.entries) {
      await go(tester, router, '/purchase?type=${entry.key}');
      expect(
        find.text(entry.value),
        findsWidgets,
        reason: 'after landing on ${entry.key} the action must say '
            '"${entry.value}"',
      );
    }
    await teardown(tester);
  });

  testWidgets('parties: customers and vendors follow the route', (tester) async {
    final router = await pumpApp(tester, location: '/parties?type=customer');
    expect(find.text('New party'), findsWidgets);

    await go(tester, router, '/parties?type=supplier');

    expect(find.text('New vendor'), findsWidgets);
    expect(find.text('Vendors'), findsWidgets);
    expect(find.text('New party'), findsNothing);
    await teardown(tester);
  });

  testWidgets('a deep link into a type that was never visited works cold',
      (tester) async {
    // The other direction of the same bug: the type must not depend on what the
    // session did earlier either.
    final router = await pumpApp(tester, location: '/sales?type=invoice');
    await go(tester, router, '/parties?type=supplier');
    await go(tester, router, '/sales?type=delivery_note');

    expect(find.text('New delivery note'), findsWidgets);
    expect(find.text('New invoice'), findsNothing);
    await teardown(tester);
  });
}
