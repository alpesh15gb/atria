@Tags(['golden'])
library;

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/dashboard/dashboard_screen.dart';
import 'package:atria/features/sales/sales_list_screen.dart';
import 'package:atria/features/parties/parties_screen.dart';
import 'package:atria/features/items/items_screen.dart';
import 'package:atria/features/reports/reports_screen.dart';
import 'package:atria/features/settings/settings_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden captures of the main screens in *light* mode, so a human (or Claude)
/// can eyeball them for unreadable text instead of trusting contrast math on
/// isolated pairs.
///
/// Tagged `golden` and excluded from the default suite: each capture holds
/// drift streams open, and their teardown is slow to settle, which blows past
/// the default per-test timeout. Regenerate on demand with:
///
///   flutter test --tags golden --update-goldens test/golden_light_mode_test.dart
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    // DemoSeeder spawns a background isolate, which flutter_test forbids, so
    // create the minimum the screens need: one firm plus a couple of parties.
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Shri Balaji Traders');
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
    // SettingsScreen awaits PackageInfo.fromPlatform(), which has no platform
    // implementation under flutter_test and would hang _loadSettings forever,
    // leaving its loading spinner spinning and pumpAndSettle to time out.
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
    // Dispose the container first: the screens' [StreamProvider]s are not
    // auto-disposed, so until the container goes away they keep drift's
    // watchAll streams open — and db.close() below will block on them,
    // which is what hung these tests for 10 minutes at a time.
    container.dispose();
    await db.close();
  });

  Future<void> capture(WidgetTester tester, String name, Widget child) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: child),
        ),
      ),
    );
    // The screens load from drift streams; let the first frames through.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile(name));
    // Unmount the tree so the screens' TextEditingController / ticker
    // listeners are cancelled. Bounded pumps rather than pumpAndSettle,
    // which would wait forever on the reports shimmer's looping animation.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  }

  // Five minutes per screen rather than the framework's ten: the capture
  // itself finishes in seconds, so anything longer means teardown is stuck on
  // an unclosed stream and should fail fast instead of stalling the run.
  // (Two minutes proved tight on slower machines — the PNG was written but
  // the drift teardown blew the budget.)
  const captureTimeout = Timeout(Duration(minutes: 5));

  testWidgets('dashboard', (tester) async {
    await capture(tester, 'goldens/light_dashboard.png', const DashboardScreen());
  }, timeout: captureTimeout);

  testWidgets('sales', (tester) async {
    await capture(tester, 'goldens/light_sales.png', const SalesListScreen());
  }, timeout: captureTimeout);

  testWidgets('parties', (tester) async {
    await capture(tester, 'goldens/light_parties.png', const PartiesScreen());
  }, timeout: captureTimeout);

  testWidgets('items', (tester) async {
    await capture(tester, 'goldens/light_items.png', const ItemsScreen());
  }, timeout: captureTimeout);

  testWidgets('reports', (tester) async {
    await capture(tester, 'goldens/light_reports.png', const ReportsScreen());
  }, timeout: captureTimeout);

  testWidgets('settings', (tester) async {
    await capture(tester, 'goldens/light_settings.png', const SettingsScreen());
  }, timeout: captureTimeout);
}
