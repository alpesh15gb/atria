import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/core/theme/app_typography.dart';
import 'package:atria/features/dashboard/dashboard_screen.dart';
import 'package:atria/features/expenses/expenses_screen.dart';
import 'package:atria/features/items/items_screen.dart';
import 'package:atria/features/ledger/chart_of_accounts_screen.dart';
import 'package:atria/features/ledger/journal_list_screen.dart';
import 'package:atria/features/parties/parties_screen.dart';
import 'package:atria/features/payments/payments_screen.dart';
import 'package:atria/features/pos/pos_screen.dart';
import 'package:atria/features/purchase/purchase_list_screen.dart';
import 'package:atria/features/recycle_bin/recycle_bin_screen.dart';
import 'package:atria/features/reports/reports_screen.dart';
import 'package:atria/features/sales/sales_list_screen.dart';
import 'package:atria/features/stock/stock_screen.dart';
import 'package:atria/shared/widgets/atria_page_header.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every tab has to survive the narrowest screen the app is sold on.

/// A 360dp Android phone is the floor. A layout that works at 800dp (what the
/// goldens capture) can still overflow here: a Row of fixed-width fields that
/// fits a tablet is a RenderFlex exception on a phone, which renders as a
/// yellow-and-black stripe in debug and as clipped, unusable content in
/// release. This pumps each tab at 360 x 640 and asks Flutter whether any such
/// error happened — the framework reports overflows through the same channel
/// as thrown exceptions, so `takeException` is the check.
///
/// The app's font is Inter, which is considerably narrower than the fallback
/// the test binding uses. A Row that fits in Inter can overflow in the fallback
/// and vice versa, so the real font is registered first — otherwise the widths
/// measured here are not the widths a phone will see.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  /// Registers the app's bundled Inter weights so text laid out in this file
  /// has the metrics a real phone gets. Idempotent: [FontLoader.load] is only
  /// awaited once per process.
  Future<void> loadAppFont() async {
    final loader = FontLoader(AppTypography.family);
    loader.addFont(rootBundle.load('assets/fonts/Inter[opsz,wght].ttf'));
    loader.addFont(rootBundle.load('assets/fonts/Inter-Italic[opsz,wght].ttf'));
    await loader.load();
  }

  /// Boots a database and a container for one screen, the way the app boots.
  Future<(AppDatabase, ProviderContainer)> boot() async {
    await loadAppFont();
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Shri Balaji Traders');
    // Resolving the gate before selecting means the controller's own restore
    // cannot land after this container is torn down and report a spurious
    // "used after dispose".
    await container.read(activeFirmIdProvider.notifier).ready;
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
    return (db, container);
  }

  /// Pumps [child] at a phone viewport and reads back anything Flutter
  /// objected to while building it.
  ///
  /// Bounded pumps, never pumpAndSettle: a live drift watch keeps a stream
  /// pending, and settling waits on it forever. [dispose] is the caller's job
  /// because the exception has to be read *before* the container goes away.
  Future<Object?> pumpScreen(
    WidgetTester tester,
    ProviderContainer container,
    Widget child, {
    Size size = const Size(360, 640),
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: platform),
          home: Scaffold(body: child),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // A second pass after the watches have emitted: the screens rebuild with
    // their real data, and that is the tree most likely to overflow.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return tester.takeException();
  }

  /// Tears the container and the database down the way a screen holding a
  /// drift watch needs: the existence watch [ActiveFirmController.select]
  /// installs keeps stream teardown timers pending, and they only fire when
  /// the fake clock is pumped *after* the container is disposed. See
  /// [stock_screen_regression_test] for the same workaround.
  Future<void> dispose(
    WidgetTester tester,
    AppDatabase db,
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
    await db.close();
  }

  // Each tab, in the size class where it is most likely to break.
  for (final entry in _tabs.entries) {
    testWidgets(
      '${entry.key} renders at 360dp without overflowing',
      timeout: timeout,
      (tester) async {
        final (db, container) = await boot();
        final error = await pumpScreen(tester, container, entry.value());
        await dispose(tester, db, container);
        expect(
          error,
          isNull,
          reason: '${entry.key} overflows or errors at a 360dp phone width',
        );
      },
    );
  }

  /// A desktop window is the other end. A screen that *fits* at 360dp can
  /// still be wrong at 1920dp: content stretched edge to edge so a line of
  /// totals runs six feet across the desk. This asks only that nothing errors;
  /// the "is it readable" judgement is the goldens' job.
  testWidgets(
    'the dashboard renders at 1920dp without overflowing',
    timeout: timeout,
    (tester) async {
      final (db, container) = await boot();
      final error = await pumpScreen(
        tester,
        container,
        const DashboardScreen(),
        size: const Size(1920, 1080),
        platform: TargetPlatform.windows,
      );
      await dispose(tester, db, container);
      expect(error, isNull);
    },
  );

  /// "No error" is not the same as "laid out well": a 1920px-wide list of
  /// document rows is unreadable past the middle, and nothing in the framework
  /// complains about it. So the wide window is also measured — the list's own
  /// heading has to stop well short of the window edge. The cap is 1280, and
  /// the header is inside the constrained box, so anything near 1920px means
  /// the frame stopped centring.
  testWidgets(
    'the sales list caps its column at a reading width on 1920dp',
    timeout: timeout,
    (tester) async {
      final (db, container) = await boot();
      final error = await pumpScreen(
        tester,
        container,
        const SalesListScreen(),
        size: const Size(1920, 1080),
        platform: TargetPlatform.windows,
      );
      final headerWidth = tester.getRect(find.byType(AtriaPageHeader)).width;
      await dispose(tester, db, container);
      expect(error, isNull);
      expect(
        headerWidth,
        lessThan(1500),
        reason:
            'the sales list stretches edge to edge on a 1920dp window; '
            'the frame should centre it at a reading width',
      );
      expect(
        headerWidth,
        greaterThan(1000),
        reason:
            'the sales list column is narrower than its content needs at '
            '1920dp',
      );
    },
  );
}

/// The tabs a user lands on, in navigation order.
final Map<String, Widget Function()> _tabs = {
  'dashboard': () => const DashboardScreen(),
  'sales': () => const SalesListScreen(),
  'parties': () => const PartiesScreen(),
  'items': () => const ItemsScreen(),
  'pos': () => const PosScreen(),
  'stock': () => const StockScreen(),
  'expenses': () => const ExpensesScreen(),
  'payments': () => const PaymentsScreen(),
  'purchases': () => const PurchaseListScreen(),
  'journal': () => const JournalListScreen(),
  'chart of accounts': () => const ChartOfAccountsScreen(),
  'reports': () => const ReportsScreen(),
  'recycle bin': () => const RecycleBinScreen(),
};
