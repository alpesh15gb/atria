import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/items/items_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression cover for the user reports "i saved an item its not showing" and
/// "when i save an items its blank": the Items tab rendered a completely blank
/// pane — no app bar, no stats, no item cards — even though the row existed in
/// the database. The grid built each row as `Row(crossAxisAlignment: stretch)`
/// directly under a sliver: the sliver hands rows unbounded height, `stretch`
/// forwarded that infinity to the cards, and the "BoxConstraints forces an
/// infinite height" exception killed the frame the moment ONE item existed.
/// (Swapping in IntrinsicHeight instead produced an infinite relayout loop —
/// also a hang. Top-aligned rows are the fix.) The empty-list layout — all
/// goldens, all prior tests — never built a row, so every check stayed green
/// while the real app went blank.
///
/// Mounts [ItemsScreen] directly, the same harness as the items golden, whose
/// teardown is known to settle (unlike tests that mount the nine-branch nav
/// shell; see `.claude/STATE.md`).
void main() {
  // Two minutes, not the framework's ten: this project has a history of
  // drift-teardown stalls; a hang should fail fast with a stack instead.
  const timeout = Timeout(Duration(minutes: 2));

  testWidgets('items tab renders a saved item instead of a blank pane',
      (tester) async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );

    // Seed exactly what the user did on Windows: one firm, one saved item.
    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
    await db.itemRepositoryFor(firm.id).create(
          name: 'kkskks',
          salePrice: 444,
          gstRate: 18,
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: ItemsScreen()),
        ),
      ),
    );
    // Drift streams deliver on the next turn(s); bounded pumps.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // A layout crash here used to blank the whole pane — surface it loudly.
    expect(tester.takeException(), isNull);
    expect(find.text('Items'), findsOneWidget);
    expect(find.text('Stock value (sale)'), findsOneWidget,
        reason: 'the stats row must render above the list');
    expect(find.text('kkskks'), findsOneWidget,
        reason: 'the saved item card must render in the Items tab');

    // Unmount so drift's stream-teardown timers fire inside this test's fake
    // async. The pumps must advance the fake clock in >=1s steps: with a
    // non-empty watched query, shorter steps left db.close() below hanging
    // forever (the empty-table case never hung — which is why the goldens
    // never caught this).
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  }, timeout: timeout);
}
