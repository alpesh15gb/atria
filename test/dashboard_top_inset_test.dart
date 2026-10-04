import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/dashboard/dashboard_screen.dart';
import 'package:atria/shared/widgets/adaptive_nav_shell.dart';
import 'package:atria/shared/widgets/atria_top_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The dashboard must not draw the status bar twice.
///
/// `AdaptiveNavShell` puts `AtriaTopBar` above the branch navigators, and
/// `AtriaTopBar` insets itself with `SafeArea` so the wordmark clears the
/// clock and the battery. But `SafeArea` only consumes the padding for its own
/// subtree — and `AtriaTopBar` is a *sibling* of `Expanded(navigationShell)` in
/// the shell's `Column`, not an ancestor of it. So the dashboard still sees the
/// original `MediaQuery.padding.top`.
///
/// The dashboard's greeting is a `SliverAppBar`, and `SliverAppBar` is
/// `primary: true` by default, which prepends `MediaQuery.padding.top` to its
/// own height and leaves that much blank space above the toolbar row. The
/// result on a phone is a dead band roughly a status bar tall, between the app
/// chrome and the greeting, with nothing in it.
///
/// The sibling detail screens are a different case and must keep their inset:
/// `_BottomShell._isEditorOrDetailRoute` drops the top bar for `/detail/…`, so
/// that route has nothing above it to have already drawn the inset.
void main() {
  const timeout = Timeout(Duration(minutes: 3));

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

  /// A phone with a 24dp status bar (72 physical px at 3.0).
  ///
  /// 412dp rather than 360dp: `flutter test` substitutes a fixed-width font
  /// where every glyph is the same box, which makes the dashboard's
  /// "Business snapshot" / "Oct 2026" Row (dashboard_screen.dart:420) overflow
  /// by ~41px at 360dp. That overflow is an artefact of the stub font — with
  /// Roboto the pair is ~180px in 290px — and it would fail this test before
  /// the assertion below ever ran. The double status-bar inset being measured
  /// here does not depend on width at all.
  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1236, 2800);
    tester.view.devicePixelRatio = 3.0;
    tester.view.padding = const FakeViewPadding(top: 72);
    addTearDown(tester.view.reset);
  }

  Future<void> pumpApp(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/dashboard',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => AdaptiveNavShell(
            navigationShell: shell,
          ),
          branches: [
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/dashboard',
                builder: (context, state) => const DashboardScreen(),
              ),
            ]),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> teardown(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('the dashboard does not re-inset for a status bar already drawn '
      'by the chrome', (tester) async {
    timeout;
    usePhone(tester);
    await pumpApp(tester);

    // Precondition: the chrome really is there, and really did absorb the
    // status bar itself.
    final topBar = tester.getRect(find.byType(AtriaTopBar));
    final statusBar = tester.view.padding.top / tester.view.devicePixelRatio;
    expect(statusBar, greaterThan(0), reason: 'the test needs a status bar');
    expect(
      topBar.height,
      greaterThan(statusBar),
      reason: 'the top bar must contain the status bar inset',
    );

    // The greeting's first line, which renders whether or not the firm stream
    // has resolved — awaiting that drift `StreamProvider` inside a widget test
    // deadlocks, and it is not what is being measured. Both lines are
    // single-line and in the same toolbar row either way, so the row's position
    // does not depend on the firm having loaded.
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good Morning'
        : hour < 17
            ? 'Good Afternoon'
            : 'Good Evening';

    final greetingTop = tester.getRect(find.text(greeting)).top;

    final gap = greetingTop - topBar.bottom;

    expect(
      gap,
      lessThan(statusBar),
      reason: 'the greeting sits $gap px below the chrome, but the '
          '$statusBar px status bar was already drawn above it — that band is '
          'dead space',
    );

    await teardown(tester);
  });
}
