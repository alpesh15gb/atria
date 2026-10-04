import 'dart:async';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/router/app_router.dart';
import 'package:atria/core/state/providers.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression cover for the Android bug where the app relaunched onto
/// go_router's default "Page not found — The route /onboarding/firm-setup does
/// not exist." screen.
///
/// The old [AtriaApp] swapped `routerConfig` between a splash-only boot router
/// (which knew only `/` and had no errorBuilder) and the real router once the
/// persisted flags had loaded. On Android the engine re-delivers the last
/// route — `/onboarding/firm-setup` here — as the platform's default route at
/// relaunch (go_router's `_effectiveInitialLocation` honours
/// `platformDispatcher.defaultRouteName` over `initialLocation`), and the
/// splash-only router could not match it, so the error page rendered before
/// the real router ever mounted. Windows never saw this: its cold starts
/// always launch at `/`.
///
/// The fix keeps ONE router for the app's lifetime: the splash is now the
/// `/boot` route inside it, the redirect parks every location on `/boot` until
/// initialization resolves (pulsed back in via `refreshListenable`), remembers
/// the parked launch location, and resumes it — never 404'ing it.
///
/// Deliberately NO test mounts the nine-branch nav shell beyond onboarding:
/// holding all branch streams open is what stalled teardowns for minutes (see
/// `.claude/STATE.md`). The returning-user redirect is already covered by
/// `onboarding_flow_test.dart` at the decision-function level.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Android relaunch: a non-root platform route parks on the splash until '
      'initialization resolves, then resumes there — never an error page',
      (tester) async {
    // A database whose open is held back until we open the gate, so the
    // splash phase is observable instead of racing the first frame.
    final gate = Completer<void>();
    var heldBack = false;
    final gatedDb = AppDatabase.test(
      _GateExecutor(NativeDatabase.memory(), onBlock: () async {
        if (!heldBack) {
          heldBack = true;
          await gate.future;
        }
      }),
    );
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(gatedDb)],
    );

    tester.view.platformDispatcher.defaultRouteNameTestValue =
        '/onboarding/firm-setup';
    final router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    // One pump so the boot-scope writes run and the splash is on screen.
    await tester.pump();

    // The platform delivered a route the app is not ready to resolve; the
    // single router parked it on the splash instead of erroring.
    expect(find.byType(BootRoute), findsOneWidget);
    expect(find.text('Page not found'), findsNothing);
    expect(find.textContaining('does not exist'), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, bootRoute);

    gate.complete();
    await container.read(appInitializationProvider.future);
    await tester.pump();
    // Bounded pumps, never pumpAndSettle: hidden screens animate forever.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(find.text('Page not found'), findsNothing);
    expect(router.routeInformationProvider.value.uri.path,
        '/onboarding/firm-setup',
        reason: 'the relaunched route is resumed, not discarded');

    // Unmount so drift's stream-teardown timers fire inside this test's fake
    // async instead of stalling db.close() below.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    container.dispose();
    await gatedDb.close();
  });

  testWidgets('a genuinely unknown route shows a recoverable error page',
      (tester) async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // A fresh database has neither flag: boot correctly lands on onboarding.
    expect(router.routeInformationProvider.value.uri.path, '/onboarding');
    expect(find.byType(BootRoute), findsNothing,
        reason: 'the splash must hand off once initialization resolved');

    // Flip the flags in memory (init already finished, so there is no
    // startup race) to become a fully configured user...
    final firm = await db.firmRepository.create(name: 'Test Trading Co.');
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
    await container.read(onboardingDoneProvider.notifier).complete();

    // ...and only NOW can an unknown route reach the error page: while
    // onboarding is pending the redirect rewrites everything to /onboarding
    // instead, which is correct.
    router.go('/definitely/not/a/route');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(find.text('Page not found'), findsOneWidget);
    // It offers a way out, unlike the old bare dead end.
    expect(find.text('Go to dashboard'), findsOneWidget);

    // The active-firm controller installs a drift existence watch on select.
    // Its teardown timer starts when the container is disposed, so the pumps
    // have to come AFTER the dispose — pumping first advances nothing, and
    // db.close() then hangs until the test times out.
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  });

  group('resolveOnboardingRedirect', () {
    String? resolve({
      required bool onboardingDone,
      String? activeFirmId,
      required String path,
    }) {
      return resolveOnboardingRedirect(
        onboardingDone: onboardingDone,
        activeFirmId: activeFirmId,
        path: path,
      );
    }

    test(
        'firm-setup stays reachable once a firm exists (Add another business)',
        () {
      // Before the fix this bounced straight back to the dashboard, making
      // Settings → "Add another business" appear to do nothing forever.
      expect(
        resolve(
            onboardingDone: true, activeFirmId: 'f1',
            path: '/onboarding/firm-setup'),
        isNull,
      );
      // ...while the welcome pages remain a dead end for a configured user.
      expect(
        resolve(onboardingDone: true, activeFirmId: 'f1', path: '/onboarding'),
        '/dashboard',
      );
    });
  });
}

/// A [QueryExecutor] that delays the very first `ensureOpen` until [onBlock]
/// completes — a stand-in for the real app's async database open, which under
/// an in-memory executor resolves so fast the boot phase would be unobservable.
class _GateExecutor extends QueryExecutor {
  _GateExecutor(this._inner, {required this.onBlock});

  final QueryExecutor _inner;
  final Future<void> Function() onBlock;
  var _held = false;

  @override
  Future<void> close() => _inner.close();

  @override
  SqlDialect get dialect => _inner.dialect;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    if (!_held) {
      _held = true;
      await onBlock();
    }
    return _inner.ensureOpen(user);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
          String statement, List<Object?> args) =>
      _inner.runSelect(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _inner.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _inner.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      _inner.runDelete(statement, args);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _inner.runCustom(statement, args);

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _inner.runBatched(statements);

  @override
  TransactionExecutor beginTransaction() => _DelegatingTransactionExecutor(
        _inner.beginTransaction(),
      );

  @override
  QueryExecutor beginExclusive() => _inner.beginExclusive();
}

/// Forwards transaction calls to the inner executor's transaction, so drift
/// can keep using transactions through the gate.
class _DelegatingTransactionExecutor implements TransactionExecutor {
  _DelegatingTransactionExecutor(this._inner);

  final TransactionExecutor _inner;

  @override
  Future<void> close() => _inner.close();

  @override
  SqlDialect get dialect => _inner.dialect;

  @override
  bool get supportsNestedTransactions => _inner.supportsNestedTransactions;

  @override
  Future<void> send() => _inner.send();

  @override
  Future<void> rollback() => _inner.rollback();

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) => _inner.ensureOpen(user);

  @override
  Future<List<Map<String, Object?>>> runSelect(
          String statement, List<Object?> args) =>
      _inner.runSelect(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _inner.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _inner.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      _inner.runDelete(statement, args);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _inner.runCustom(statement, args);

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _inner.runBatched(statements);

  @override
  TransactionExecutor beginTransaction() => _inner.beginTransaction();

  @override
  QueryExecutor beginExclusive() => _inner.beginExclusive();
}
