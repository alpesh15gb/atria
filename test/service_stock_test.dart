import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/items/item_editor_screen.dart';
import 'package:atria/features/stock/stock_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A service is not physical goods, so it has no place in the stock ledger.

/// Both stock-movement writers already refuse to touch one
/// (`item_repository.dart` and `sales_repository.dart` both test
/// `item.isService || item.stockType != 'tracked'`), but the *read* side only
/// ever looked at `stockType`, and the item editor kept the two toggles
/// independent. So a service left 'tracked' carried a frozen opening balance
/// into stock valuation, the stock summary and every low-stock alert forever.
///
/// The editor now forces services untracked, and the aggregates now apply the
/// same test the writers do.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(name: 'Apex Traders');
    firmId = firm.id;
  });

  tearDown(() => db.close());

  /// Tears a container down the way a screen holding a drift watch needs: the
  /// existence watch [ActiveFirmController.select] installs keeps stream
  /// teardown timers pending, and they only fire when the fake clock is
  /// pumped. Without the >=1s steps, [AppDatabase.close] in the file-level
  /// tearDown hangs until the test's timeout. See
  /// [stock_screen_regression_test] for the same workaround.
  Future<void> disposeWithMountedDrift(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  test('a service left tracked does not reach the stock totals',
      timeout: timeout, () async {
    final items = db.itemRepositoryFor(firmId);

    // The inconsistent state the fix defends against: a service that is also
    // marked stock-tracked, with an opening balance and a low-stock alert.
    await items.create(
      name: 'Site visit',
      salePrice: 500,
      isService: true,
      stockType: 'tracked',
      openingStock: 10,
      lowStockAlert: 5,
    );
    // A goods item that is genuinely low, so the alert is not empty and the
    // service cannot hide behind an empty result.
    await items.create(
      name: 'Steel Rod 12mm',
      salePrice: 250,
      openingStock: 4,
      lowStockAlert: 10,
    );

    final all = await items.all();
    final service = all.firstWhere((i) => i.isService);
    expect(service.stockType, 'tracked',
        reason: 'this test is only meaningful while the row is tracked');

    // Stock value: 4 rods at ₹250 = ₹1,000. The service's 10 x ₹500 must not
    // add ₹5,000 to it.
    expect(await items.stockValue(), 1000);

    // Low stock: the rod, not the service.
    final low = await items.lowStock();
    expect(low.map((i) => i.name).toList(), ['Steel Rod 12mm']);

    // And the report-level summary agrees with the repository.
    final summary = await db.reportRepositoryFor(firmId).stockSummary();
    expect(summary.map((r) => r.name).toList(), ['Steel Rod 12mm']);
  });

  testWidgets('picking Service switches stock tracking off and locks it',
      timeout: timeout, (tester) async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    await container.read(activeFirmIdProvider.notifier).select(firmId);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: ItemEditorScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The form starts as a tracked goods item.
    expect(find.text('Stock tracking'), findsOneWidget);

    await tester.tap(find.text('Service'));
    await tester.pumpAndSettle();

    // The linkage fired: the control moved to Untracked, went read-only, and
    // said why instead of silently changing.
    final toggle = tester.widget<SegmentedButton<String>>(
      find.byType(SegmentedButton<String>),
    );
    expect(toggle.selected, {'untracked'});
    for (final segment in toggle.segments) {
      expect(segment.enabled, isFalse,
          reason: 'a service cannot be stock-tracked');
    }
    expect(find.text("A service isn't counted in stock."), findsOneWidget);

    // Saving a service then stores it untracked even if the value had been
    // left tracked somehow.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Item name *'),
      'Consulting visit',
    );
    // The save refuses to write a row whose prices don't parse, so give them
    // a value rather than rely on an empty-field default.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Sale price *'),
      '500',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Purchase price'),
      '0',
    );
    await tester.pump();
    await tester.tap(find.text('Save and close'));
    await tester.pumpAndSettle();

    final saved = (await db.itemRepositoryFor(firmId).all()).single;
    expect(saved.isService, isTrue);
    expect(saved.stockType, 'untracked');

    await disposeWithMountedDrift(tester, container);
  });

  testWidgets('the summary refreshes when stock moves outside the screen',
      timeout: timeout, (tester) async {
    final items = db.itemRepositoryFor(firmId);
    await items.create(
      name: 'Steel Rod 12mm',
      salePrice: 250,
      openingStock: 10,
      lowStockAlert: 2,
    );

    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    await container.read(activeFirmIdProvider.notifier).select(firmId);

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

    // The tab stays mounted under the nav shell, so without a dependency on the
    // movement log this row would read 10 until the app restarted.
    await items.applyStockEffect(
      itemId: (await items.all()).single.id,
      quantity: -3,
      kind: 'sale',
      source: 'manual',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The movement landed while the screen stayed mounted, so the row the user
    // reads is the new balance, not the one from when the tab was opened.
    final row = (await db.reportRepositoryFor(firmId).stockSummary()).single;
    expect(row.stock, 7);

    // And the screen re-rendered with it: the summary it displays is the
    // re-read, which is what the signal dependency exists to force. Bounded
    // pumps rather than pumpAndSettle — a live drift watch keeps a stream
    // pending, and settling waits on it forever.
    expect(find.text('7'), findsNWidgets(2),
        reason: 'the stock column and the header quantity total');

    // The screen holds a drift watch open. Unmount with >=1s steps after
    // dispose, or the stream-teardown timers never fire inside fake async and
    // db.close() hangs — see the matching teardown in
    // stock_screen_regression_test.dart.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  });

  testWidgets('a duplicate SKU is refused with the name of its owner',
      timeout: timeout, (tester) async {
    final items = db.itemRepositoryFor(firmId);
    await items.create(name: 'Basmati Rice 1 kg', sku: 'RICE-1');

    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    await container.read(activeFirmIdProvider.notifier).select(firmId);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: ItemEditorScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Item name *'),
      'Basmati Rice 5 kg',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'SKU / code'),
      'rice-1', // different case, same code: a label is read, not memorised.
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'Sale price *'), '90');
    await tester.enterText(find.widgetWithText(TextFormField, 'Purchase price'), '0');
    await tester.pump();
    await tester.tap(find.text('Save and close'));
    await tester.pumpAndSettle();

    // The second item was not written, and the user is told which row owns the
    // code rather than having to find out from a wrong lookup later.
    expect(await items.all(), hasLength(1));
    expect(
      find.text('SKU rice-1 is already used by "Basmati Rice 1 kg".'),
      findsOneWidget,
    );

    await disposeWithMountedDrift(tester, container);
  });
}
