import 'package:atria/app.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/router/app_router.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_colors.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/shared/widgets/mobile_page.dart';
import 'package:atria/shared/widgets/mobile_selection_field.dart';
import 'package:atria/shared/widgets/atria_list_page.dart';
import 'package:atria/shared/widgets/atria_page_header.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late String firmId;

  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 892);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final font = FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter[opsz,wght].ttf'));
    await font.load();
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    final firm = await db.firmRepository.create(name: 'Mobile Test Books', stateCode: '29');
    firmId = firm.id;
    await db.partyRepositoryFor(firmId).create(name: 'Acme Customer', type: 'customer', stateCode: '29');
    await db.partyRepositoryFor(firmId).create(name: 'Acme Supplier', type: 'supplier', stateCode: '29');
    await db.itemRepositoryFor(firmId).create(name: 'Blue Notebook', salePrice: 100, purchasePrice: 60, gstRate: 18);
    await container.read(activeFirmIdProvider.notifier).select(firmId);
    await container.read(onboardingDoneProvider.notifier).complete();
    await container.read(appInitializationProvider.future);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const AtriaApp()));
    await frames(tester);
    container.read(appRouterProvider).go('/dashboard');
    await frames(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) { await tester.pump(const Duration(seconds: 1)); }
    await db.close();
  }

  test('desktop palettes remain unchanged; mobile has its own charcoal/blue', () {
    expect(AppTheme.light().colorScheme.primary, AppColors.primary);
    expect(AppTheme.dark().colorScheme.primary, const Color(0xFF56C246));
    expect(AppTheme.mobile().colorScheme.primary, const Color(0xFF5263E5));
    expect(AppTheme.mobile().scaffoldBackgroundColor, const Color(0xFF1E1F21));
  });

  testWidgets('desktop list keeps the heading action and has no mobile FAB', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light().copyWith(platform: TargetPlatform.windows), home: Scaffold(body: AtriaListPage(title: 'Invoices', actions: [AtriaPrimaryAction(label: 'New invoice', onPressed: () {})], body: const Text('Desktop table')))));
    expect(find.byType(AtriaPageHeader), findsOneWidget);
    expect(find.byType(MobileListPage), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('New invoice'), findsOneWidget);
  });

  testWidgets('phone home has five destinations and More still reaches Reports', (tester) async {
    await boot(tester);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations.length, 5);
    expect(bar.destinations.cast<NavigationDestination>().map((d) => d.label), ['Home', 'Bills', 'Products', 'Parties', 'More']);
    expect(find.textContaining('SwipeAI'), findsNothing);
    expect(find.textContaining('PRO'), findsNothing);
    expect(find.text('₹0.00'), findsWidgets, reason: 'money must be rendered, not an empty fitted box');
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('More')));
    await frames(tester);
    await tester.ensureVisible(find.widgetWithText(ListTile, 'Reports'));
    await tester.tap(find.widgetWithText(ListTile, 'Reports'));
    await frames(tester);
    expect(container.read(appRouterProvider).routeInformationProvider.value.uri.path, '/reports');
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  for (final purchase in [false, true]) {
    testWidgets('mobile ${purchase ? 'purchase' : 'invoice'} picks records, saves and reopens its real line', (tester) async {
      await boot(tester);
      await tester.tap(find.text(purchase ? 'Purchase' : 'Invoice'));
      await frames(tester);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.text(purchase ? 'Select Supplier' : 'Select Customer'));
      await frames(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Search…'), 'Acme');
      await tester.tap(find.text(purchase ? 'Acme Supplier' : 'Acme Customer'));
      await frames(tester);
      await tester.tap(find.text('Select Products'));
      await frames(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Search…'), 'Notebook');
      await tester.tap(find.text('Blue Notebook'));
      await frames(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(MobileSelectionField<String>), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Save and close'));
      await frames(tester, count: 20);
      expect(find.byType(NavigationBar), findsOneWidget, reason: 'saving returns to the shell, not a blank root navigator');
      if (purchase) {
        final bills = await tester.runAsync(() => db.purchaseRepositoryFor(firmId).list());
        expect(bills, hasLength(1));
        final lines = await tester.runAsync(() => db.purchaseRepositoryFor(firmId).itemsFor(bills!.single.id));
        expect(lines!.single.name, 'Blue Notebook');
        expect(lines.single.rate, 60);
        container.read(appRouterProvider).push('/purchase/edit/${bills!.single.id}');
      } else {
        final docs = await tester.runAsync(() => db.salesRepositoryFor(firmId).list());
        expect(docs, hasLength(1));
        final lines = await tester.runAsync(() => db.salesRepositoryFor(firmId).itemsFor(docs!.single.id));
        expect(lines!.single.name, 'Blue Notebook');
        expect(lines.single.rate, 100);
        container.read(appRouterProvider).push('/sales/edit/${docs!.single.id}');
      }
      await frames(tester, count: 20);
      expect(find.widgetWithText(TextField, 'Blue Notebook'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    });
  }

  testWidgets('mobile required customer and product validation cannot be bypassed', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Invoice'));
    await frames(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save and close'));
    await frames(tester);
    expect(find.text('Please select a customer'), findsOneWidget);
    expect(await tester.runAsync(() => db.salesRepositoryFor(firmId).list()), isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('mobile bank section saves actual settings and preserves other firm fields', (tester) async {
    await boot(tester);
    final before = await tester.runAsync(() => db.firmRepository.getById(firmId));
    container.read(appRouterProvider).push('/settings/firm?section=bank');
    await frames(tester);
    expect(find.text('Bank Details'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Bank name'), 'Test Bank');
    await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
    await frames(tester, count: 20);
    final after = await tester.runAsync(() => db.firmRepository.getById(firmId));
    expect(after!.bankName, 'Test Bank');
    expect(after.name, before!.name);
    expect(after.invoicePrefix, before.invoicePrefix);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('mobile full amount remains readable at phone width', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: AppTheme.mobile(), home: Scaffold(body: SizedBox(width: 90, child: MobileAmount(Decimal.fromInt(12345678))))));
    expect(find.text('₹1,23,45,678.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> frames(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) { await tester.pump(const Duration(milliseconds: 80)); }
}
