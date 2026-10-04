import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/stock/stock_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression cover for the user report "stock summary also same issue blank":
/// the stock table's Column(crossAxisAlignment: stretch) sat under a
/// horizontal scroll view, which hands its child UNBOUNDED width; stretch
/// forwarded that infinity into the Expanded table rows and killed the frame
/// the moment one tracked item existed (empty stock rendered fine, which is
/// why the goldens missed it — same class as the blank Items grid).
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  testWidgets('stock summary renders its table with a tracked item',
      (tester) async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );

    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
    // A tracked item with stock: this is what used to crash the table.
    await db.itemRepositoryFor(firm.id).create(
          name: 'Steel Rod 12mm',
          salePrice: 250,
          purchasePrice: 180,
          gstRate: 18,
          openingStock: 40,
          lowStockAlert: 10,
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: StockScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // The page names itself in the header now (QBO sentence case, and no app
    // bar repeating the title).
    expect(find.text('Stock summary'), findsOneWidget);
    expect(find.text('Steel Rod 12mm'), findsOneWidget,
        reason: 'the item row must render in the stock table');
    expect(find.text('Item'), findsOneWidget,
        reason: 'the table header must render');

    // Unmount so drift's stream-teardown timers fire inside this test's fake
    // async; >=1s steps after dispose, or db.close() hangs (see STATE.md).
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
