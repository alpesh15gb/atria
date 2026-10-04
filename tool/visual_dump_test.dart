// Renders the app's REAL screens — the real router, the real shell chrome and
// the real widgets — into PNGs under build/visual/ so a human (or an agent
// that cannot launch the desktop window) can actually look at them.
//
// Not part of the suite: it lives outside test/ and is run explicitly.
//
//   flutter test tool/visual_dump_test.dart --update-goldens
//
// Fonts are loaded for real (Inter, MaterialIcons, Phosphor), so the captures
// show actual glyphs instead of the solid boxes `matchesGoldenFile` produces
// when no font is registered.
import 'dart:io';

import 'package:atria/app.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/router/app_router.dart';
import 'package:atria/core/services/demo_seeder.dart';
import 'package:atria/core/state/providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const Size kDesktop = Size(1440, 900);
const Size kPhone = Size(412, 892);
const Size kLaptop = Size(1280, 800);
const Size kWide = Size(1680, 950);

AppDatabase? _db;
ProviderContainer? _container;
late GoRouter router;
late String firmId;
late String invoiceId;
late String quotationId;
late String billId;
late String itemId;
late String customerId;
late String supplierId;
late String expenseId;

/// Registers a real font file with the test engine.
Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) {
      // ignore: avoid_print
      print('visual_dump: missing font $path');
      continue;
    }
    final bytes = file.readAsBytesSync();
    loader.addFont(
      Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)),
    );
  }
  await loader.load();
}

/// Where the bundled Flutter SDK keeps its material icon font.
String _materialIconsPath() {
  for (final root in ['C:/flutter', 'C:/src/flutter']) {
    final candidate =
        '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf';
    if (File(candidate).existsSync()) return candidate;
  }
  return 'C:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf';
}

Future<void> _pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadFont('Inter', ['assets/fonts/Inter[opsz,wght].ttf']);
    await _loadFont('MaterialIcons', [_materialIconsPath()]);
    const phosphor = 'third_party/phosphor_flutter/lib/fonts';
    await _loadFont('PhosphorRegular', ['$phosphor/Phosphor.ttf']);
    await _loadFont('PhosphorFill', ['$phosphor/Phosphor-Fill.ttf']);
    await _loadFont('PhosphorBold', ['$phosphor/Phosphor-Bold.ttf']);

    // One seeded database for every capture: the demo books give the screens
    // something real to show (invoices, bills, parties, stock, expenses).
    final db = AppDatabase.test(NativeDatabase.memory());
    await DemoSeeder(db).seedIfNeeded();
    _db = db;

    final firm = (await db.firmRepository.all()).first;
    firmId = firm.id;

    final sales = db.salesRepositoryFor(firmId);
    invoiceId = (await sales.list(docType: 'invoice')).first.id;
    quotationId = (await sales.list(docType: 'quotation')).first.id;
    billId = (await db.purchaseRepositoryFor(firmId).list()).first.id;

    final items = await db.itemRepositoryFor(firmId).all(limit: 100);
    itemId = items.firstWhere((i) => !i.isService).id;

    final parties = db.partyRepositoryFor(firmId);
    customerId = (await parties.all(type: 'customer')).first.id;
    supplierId = (await parties.all(type: 'supplier')).first.id;
    expenseId = (await db.expenseRepositoryFor(firmId).list()).first.id;
  });

  tearDownAll(() async {
    // drift's stream teardown is slow once a screen has held a query open;
    // the PNGs are already on disk by now, so a stuck close must not fail runs.
    await _db?.close().timeout(const Duration(seconds: 20), onTimeout: () {});
  });

  setUp(() async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(_db!)],
    );
    _container = container;

    // Boot gate: onboarding done + an active firm, exactly as a returning
    // user's app starts.
    await container.read(onboardingDoneProvider.notifier).complete();
    await container.read(activeFirmIdProvider.notifier).select(firmId);
    await container.read(appInitializationProvider.future);

    // SettingsScreen awaits PackageInfo.fromPlatform().
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
          (call) async {
            if (call.method != 'getAll') return null;
            return <String, dynamic>{
              'appName': 'Atria',
              'packageName': 'com.example.atria',
              'version': '1.0.0',
              'buildNumber': '1',
              'installerStore': null,
            };
          },
        );
  });

  tearDown(() async {
    _container?.dispose();
    _container = null;
  });

  /// Boots the real app at [size], navigates to [route] and writes the frame
  /// to build/visual/<name>.png.
  Future<void> shoot(
    WidgetTester tester,
    String name,
    String route, {
    Size size = kDesktop,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: _container!,
        child: const AtriaApp(),
      ),
    );
    await _pumpFrames(tester);

    // Resolve the router only after the first frame: reading it earlier would
    // freeze the boot redirect on a container that had not settled yet.
    router = _container!.read(appRouterProvider);
    router.go(route);
    await _pumpFrames(tester, frames: 12);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../build/visual/$name.png'),
    );

    // Unmount so the next capture starts from a clean tree.
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester, frames: 2);
  }

  final t = Timeout(Duration(minutes: 3));

  // ---- Dashboard / lists -------------------------------------------------
  testWidgets('dashboard', (w) async {
    await shoot(w, 'dashboard', '/dashboard');
  }, timeout: t);

  testWidgets('sales', (w) async {
    await shoot(w, 'sales', '/sales');
  }, timeout: t);

  testWidgets('sales-quotations', (w) async {
    await shoot(w, 'sales_quotations', '/sales?type=quotation');
  }, timeout: t);

  testWidgets('purchase', (w) async {
    await shoot(w, 'purchase', '/purchase');
  }, timeout: t);

  testWidgets('items', (w) async {
    await shoot(w, 'items', '/items');
  }, timeout: t);

  testWidgets('parties-customers', (w) async {
    await shoot(w, 'parties_customers', '/parties?type=customer');
  }, timeout: t);

  testWidgets('parties-vendors', (w) async {
    await shoot(w, 'parties_vendors', '/parties?type=supplier');
  }, timeout: t);

  testWidgets('payments', (w) async {
    await shoot(w, 'payments', '/payments');
  }, timeout: t);

  testWidgets('expenses', (w) async {
    await shoot(w, 'expenses', '/expenses');
  }, timeout: t);

  testWidgets('stock', (w) async {
    await shoot(w, 'stock', '/stock');
  }, timeout: t);

  testWidgets('reports', (w) async {
    await shoot(w, 'reports', '/reports');
  }, timeout: t);

  testWidgets('gst-reports', (w) async {
    await shoot(w, 'gst_reports', '/gst-reports');
  }, timeout: t);

  testWidgets('statements', (w) async {
    await shoot(w, 'statements', '/statements');
  }, timeout: t);

  testWidgets('payment-reminders', (w) async {
    await shoot(w, 'payment_reminders', '/payment-reminders');
  }, timeout: t);

  testWidgets('settings', (w) async {
    await shoot(w, 'settings', '/settings');
  }, timeout: t);

  testWidgets('settings-firm', (w) async {
    await shoot(w, 'settings_firm', '/settings/firm');
  }, timeout: t);

  testWidgets('settings-backup', (w) async {
    await shoot(w, 'settings_backup', '/settings/backup');
  }, timeout: t);

  testWidgets('settings-recycle-bin', (w) async {
    await shoot(w, 'settings_recycle_bin', '/settings/recycle-bin');
  }, timeout: t);

  testWidgets('settings-period-lock', (w) async {
    await shoot(w, 'settings_period_lock', '/settings/period-lock');
  }, timeout: t);

  testWidgets('settings-audit-log', (w) async {
    await shoot(w, 'settings_audit_log', '/settings/audit-log');
  }, timeout: t);

  // ---- Documents ---------------------------------------------------------
  testWidgets('sale-new', (w) async {
    await shoot(w, 'sale_new', '/sales/new');
  }, timeout: t);

  testWidgets('sale-edit', (w) async {
    await shoot(w, 'sale_edit', '/sales/edit/$invoiceId');
  }, timeout: t);

  testWidgets('sale-detail', (w) async {
    await shoot(w, 'sale_detail', '/sales/detail/$invoiceId');
  }, timeout: t);

  testWidgets('quotation-new', (w) async {
    await shoot(w, 'quotation_new', '/sales/new?type=quotation');
  }, timeout: t);

  testWidgets('purchase-new', (w) async {
    await shoot(w, 'purchase_new', '/purchase/new');
  }, timeout: t);

  testWidgets('purchase-edit', (w) async {
    await shoot(w, 'purchase_edit', '/purchase/edit/$billId');
  }, timeout: t);

  testWidgets('item-new', (w) async {
    await shoot(w, 'item_new', '/items/new');
  }, timeout: t);

  testWidgets('item-edit', (w) async {
    await shoot(w, 'item_edit', '/items/edit/$itemId');
  }, timeout: t);

  testWidgets('party-new', (w) async {
    await shoot(w, 'party_new', '/parties/new?type=customer');
  }, timeout: t);

  testWidgets('party-edit', (w) async {
    await shoot(w, 'party_edit', '/parties/edit/$customerId');
  }, timeout: t);

  testWidgets('party-statement', (w) async {
    await shoot(w, 'party_statement', '/parties/statement/$customerId');
  }, timeout: t);

  testWidgets('expense-new', (w) async {
    await shoot(w, 'expense_new', '/expenses/new');
  }, timeout: t);

  testWidgets('expense-edit', (w) async {
    await shoot(w, 'expense_edit', '/expenses/edit/$expenseId');
  }, timeout: t);

  testWidgets('income-new', (w) async {
    await shoot(w, 'income_new', '/expenses/new?type=income');
  }, timeout: t);

  // ---- Laptop width (13" laptop, the common desktop case) ----------------
  testWidgets('laptop-dashboard', (w) async {
    await shoot(w, 'laptop_dashboard', '/dashboard', size: kLaptop);
  }, timeout: t);

  testWidgets('laptop-sale-edit', (w) async {
    await shoot(w, 'laptop_sale_edit', '/sales/edit/$invoiceId', size: kLaptop);
  }, timeout: t);

  testWidgets('laptop-purchase-new', (w) async {
    await shoot(w, 'laptop_purchase_new', '/purchase/new', size: kLaptop);
  }, timeout: t);

  // ---- Maximised window (1680) — the width a centred form wastes ---------
  testWidgets('wide-sale-edit', (w) async {
    await shoot(w, 'wide_sale_edit', '/sales/edit/$invoiceId', size: kWide);
  }, timeout: t);

  testWidgets('wide-sale-new', (w) async {
    await shoot(w, 'wide_sale_new', '/sales/new', size: kWide);
  }, timeout: t);

  testWidgets('wide-item-new', (w) async {
    await shoot(w, 'wide_item_new', '/items/new', size: kWide);
  }, timeout: t);

  testWidgets('wide-party-new', (w) async {
    await shoot(w, 'wide_party_new', '/parties/new?type=customer', size: kWide);
  }, timeout: t);

  testWidgets('wide-expense-new', (w) async {
    await shoot(w, 'wide_expense_new', '/expenses/new', size: kWide);
  }, timeout: t);

  testWidgets('wide-purchase-new', (w) async {
    await shoot(w, 'wide_purchase_new', '/purchase/new', size: kWide);
  }, timeout: t);

  // ---- Phone width -------------------------------------------------------
  testWidgets('phone-dashboard', (w) async {
    await shoot(w, 'phone_dashboard', '/dashboard', size: kPhone);
  }, timeout: t);

  testWidgets('phone-sales', (w) async {
    await shoot(w, 'phone_sales', '/sales', size: kPhone);
  }, timeout: t);

  testWidgets('phone-sale-new', (w) async {
    await shoot(w, 'phone_sale_new', '/sales/new', size: kPhone);
  }, timeout: t);

  testWidgets('phone-sale-edit', (w) async {
    await shoot(w, 'phone_sale_edit', '/sales/edit/$invoiceId', size: kPhone);
  }, timeout: t);

  testWidgets('phone-sale-detail', (w) async {
    await shoot(
      w,
      'phone_sale_detail',
      '/sales/detail/$invoiceId',
      size: kPhone,
    );
  }, timeout: t);

  testWidgets('phone-items', (w) async {
    await shoot(w, 'phone_items', '/items', size: kPhone);
  }, timeout: t);

  testWidgets('phone-item-edit', (w) async {
    await shoot(w, 'phone_item_edit', '/items/edit/$itemId', size: kPhone);
  }, timeout: t);

  testWidgets('phone-parties', (w) async {
    await shoot(w, 'phone_parties', '/parties?type=customer', size: kPhone);
  }, timeout: t);

  testWidgets('phone-party-edit', (w) async {
    await shoot(
      w,
      'phone_party_edit',
      '/parties/edit/$customerId',
      size: kPhone,
    );
  }, timeout: t);

  testWidgets('phone-purchase-new', (w) async {
    await shoot(w, 'phone_purchase_new', '/purchase/new', size: kPhone);
  }, timeout: t);

  testWidgets('phone-expense-new', (w) async {
    await shoot(w, 'phone_expense_new', '/expenses/new', size: kPhone);
  }, timeout: t);

  testWidgets('phone-payments', (w) async {
    await shoot(w, 'phone_payments', '/payments', size: kPhone);
  }, timeout: t);

  testWidgets('phone-stock', (w) async {
    await shoot(w, 'phone_stock', '/stock', size: kPhone);
  }, timeout: t);

  testWidgets('phone-reports', (w) async {
    await shoot(w, 'phone_reports', '/reports', size: kPhone);
  }, timeout: t);

  testWidgets('phone-settings', (w) async {
    await shoot(w, 'phone_settings', '/settings', size: kPhone);
  }, timeout: t);
}
