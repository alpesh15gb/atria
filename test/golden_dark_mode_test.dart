@Tags(['golden'])
library;

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/dashboard/dashboard_screen.dart';
import 'package:atria/features/items/items_screen.dart';
import 'package:atria/features/ledger/chart_of_accounts_screen.dart';
import 'package:atria/features/parties/parties_screen.dart';
import 'package:atria/features/reports/reports_screen.dart';
import 'package:atria/features/sales/sales_list_screen.dart';
import 'package:atria/features/settings/settings_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden captures of the main screens in *dark* mode.
///
/// The dark scheme existed and was switchable but had no captures, so nobody
/// had ever looked at a whole screen in it: contrast on a button pair can be
/// measured, but "the list rows, the empty state and the summary card together"
/// cannot. These are the same screens as the light set, in the same order, so
/// the two folders can be compared side by side.
///
/// Tagged `golden` and excluded from the default suite — each capture holds
/// drift streams open and teardown is slow. Regenerate on demand with:
///
///   flutter test --tags golden --update-goldens test/golden_dark_mode_test.dart
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Shri Balaji Traders');
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
    // The ledger screens no longer seed the chart on build (a screen that writes
    // when it opens is a screen whose teardown can hang), so the capture seeds it
    // the way the app does at launch. Without this the chart-of-accounts frame
    // would be its empty state.
    await db.ledgerRepositoryFor(firm.id).ensureChart();
    // SettingsScreen awaits PackageInfo.fromPlatform(), which has no platform
    // implementation under flutter_test and would hang on its loading spinner.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async {
        if (call.method != 'getAll') return null;
        return <String, dynamic>{
          'appName': 'Apex Books',
          'packageName': 'com.example.atria',
          'version': '1.0.0',
          'buildNumber': '1',
          'installerStore': null,
        };
      },
    );
  });

  tearDown(() async {
    // Dispose the container first: the screens' StreamProviders are not
    // auto-disposed, and db.close() blocks on the streams they hold open.
    container.dispose();
    await db.close();
  });

  Future<void> capture(WidgetTester tester, String name, Widget child) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.dark,
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile(name));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  }

  const captureTimeout = Timeout(Duration(minutes: 5));

  testWidgets('dashboard', (tester) async {
    await capture(tester, 'goldens/dark_dashboard.png', const DashboardScreen());
  }, timeout: captureTimeout);

  testWidgets('sales', (tester) async {
    await capture(tester, 'goldens/dark_sales.png', const SalesListScreen());
  }, timeout: captureTimeout);

  testWidgets('parties', (tester) async {
    await capture(tester, 'goldens/dark_parties.png', const PartiesScreen());
  }, timeout: captureTimeout);

  testWidgets('items', (tester) async {
    await capture(tester, 'goldens/dark_items.png', const ItemsScreen());
  }, timeout: captureTimeout);

  testWidgets('reports', (tester) async {
    await capture(tester, 'goldens/dark_reports.png', const ReportsScreen());
  }, timeout: captureTimeout);

  testWidgets('settings', (tester) async {
    await capture(tester, 'goldens/dark_settings.png', const SettingsScreen());
  }, timeout: captureTimeout);

  // The ledger is the newest surface and reads a stream of accounts, so it is
  // captured in both modes: it is the screen most likely to be built with a
  // hard-coded light colour by accident.
  testWidgets('chart of accounts', (tester) async {
    await capture(tester, 'goldens/dark_chart_of_accounts.png',
        const ChartOfAccountsScreen());
  }, timeout: captureTimeout);
}
