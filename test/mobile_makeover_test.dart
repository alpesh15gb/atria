import 'package:atria/app.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/navigation/nav_destinations.dart';
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
  String? secondFirmId;

  Future<void> boot(WidgetTester tester, {bool secondFirm = false, bool mobile = true}) async {
    tester.view.physicalSize = const Size(412, 892);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final font = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter[opsz,wght].ttf'));
    await font.load();
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(
      name: 'Mobile Test Books',
      stateCode: '29',
    );
    firmId = firm.id;
    if (secondFirm) {
      secondFirmId = (await db.firmRepository.create(
        name: 'Second Business',
        stateCode: '27',
      )).id;
    }
    await db
        .partyRepositoryFor(firmId)
        .create(name: 'Acme Customer', type: 'customer', stateCode: '29');
    await db
        .partyRepositoryFor(firmId)
        .create(name: 'Acme Supplier', type: 'supplier', stateCode: '29');
    await db
        .itemRepositoryFor(firmId)
        .create(
          name: 'Blue Notebook',
          salePrice: 100,
          purchasePrice: 60,
          gstRate: 18,
        );
    await container.read(activeFirmIdProvider.notifier).select(firmId);
    await container.read(onboardingDoneProvider.notifier).complete();
    await container.read(appInitializationProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const AtriaApp()),
    );
    await frames(tester);
    container.read(appRouterProvider).go('/dashboard');
    await frames(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  }

  test(
    'desktop palettes remain unchanged; mobile has its own warm cream/teal',
    () {
      expect(AppTheme.light().colorScheme.primary, AppColors.primary);
      expect(AppTheme.dark().colorScheme.primary, const Color(0xFF56C246));
      expect(AppTheme.mobile().colorScheme.primary, const Color(0xFF00685F));
      expect(
        AppTheme.mobile().scaffoldBackgroundColor,
        const Color(0xFFFFF8F5),
      );
    },
  );

  testWidgets('app applies scale changes immediately to routed screens', (
    tester,
  ) async {
    await boot(tester);
    final screen = find.byType(NavigationBar);
    expect(MediaQuery.sizeOf(tester.element(screen)).width, 412);
    await container.read(interfaceScaleProvider.notifier).set(1.3);
    await frames(tester);
    expect(
      MediaQuery.sizeOf(tester.element(screen)).width,
      closeTo(412 / 1.3, .01),
    );
    await container.read(interfaceScaleProvider.notifier).set(.85);
    await frames(tester);
    expect(
      MediaQuery.sizeOf(tester.element(screen)).width,
      closeTo(412 / .85, .01),
    );
    await container.read(interfaceScaleProvider.notifier).set(1);
    await frames(tester);
    expect(MediaQuery.sizeOf(tester.element(screen)).width, 412);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('desktop list keeps the heading action and has no mobile FAB', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: AtriaListPage(
            title: 'Invoices',
            actions: [
              AtriaPrimaryAction(label: 'New invoice', onPressed: () {}),
            ],
            body: const Text('Desktop table'),
          ),
        ),
      ),
    );
    expect(find.byType(AtriaPageHeader), findsOneWidget);
    expect(find.byType(MobileListPage), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('New invoice'), findsOneWidget);
  });

  testWidgets('phone home has five destinations and More still reaches Reports', (
    tester,
  ) async {
    await boot(tester);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations.length, 5);
    // Each slot is labelled with **its own destination's** name.
    //
    // These were hard-coded to ['Home', 'Bills', 'Products', 'Parties'] and
    // laid over `primary[0..3]`, whose index 1 is the **Sales** branch — so the
    // tab that said "Bills" opened the Sales/Invoices list, every time, while the
    // More sheet separately carried a row also labelled "Bills". One word, two
    // different screens. Reading the label off the destination removes the class.
    final labels = bar.destinations
        .cast<NavigationDestination>()
        .map((d) => d.label)
        .toList();
    expect(labels.last, 'More');
    expect(labels[0], NavDestinations.primary[0].label);
    expect(labels[1], NavDestinations.primary[1].label);
    expect(
      labels[1],
      isNot('Bills'),
      reason: 'the second slot is the Sales branch, so it must not claim to be Bills',
    );
    expect(labels.where((l) => l == 'Bills').length, lessThanOrEqualTo(1));
    expect(find.textContaining('SwipeAI'), findsNothing);
    expect(find.textContaining('PRO'), findsNothing);
    expect(
      find.text('₹0.00'),
      findsWidgets,
      reason: 'money must be rendered, not an empty fitted box',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('More'),
      ),
    );
    await frames(tester);
    await tester.ensureVisible(find.widgetWithText(ListTile, 'Reports'));
    await tester.tap(find.widgetWithText(ListTile, 'Reports'));
    await frames(tester);
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/reports',
    );
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  for (final purchase in [false, true]) {
    testWidgets(
      'mobile ${purchase ? 'purchase' : 'invoice'} picks records, saves and reopens its real line',
      (tester) async {
        await boot(tester);
        await tester.tap(find.text(purchase ? 'Purchase' : 'Invoice'));
        await frames(tester);
        expect(find.byType(NavigationBar), findsNothing);
        await tester.tap(
          find.text(purchase ? 'Select Supplier' : 'Select Customer'),
        );
        await frames(tester);
        expect(find.byType(BottomSheet), findsOneWidget);
        await tester.enterText(
          find.widgetWithText(TextField, 'Search…'),
          'Acme',
        );
        await tester.tap(
          find.text(purchase ? 'Acme Supplier' : 'Acme Customer'),
        );
        await frames(tester);
        await tester.tap(find.text('Select Products'));
        await frames(tester);
        await tester.enterText(
          find.widgetWithText(TextField, 'Search…'),
          'Notebook',
        );
        await tester.tap(find.text('Blue Notebook'));
        await frames(tester);
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(MobileSelectionField<String>), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.tap(find.widgetWithText(FilledButton, 'Save and close'));
        await frames(tester, count: 20);
        expect(
          find.byType(NavigationBar),
          findsOneWidget,
          reason: 'saving returns to the shell, not a blank root navigator',
        );
        if (purchase) {
          final bills = await tester.runAsync(
            () => db.purchaseRepositoryFor(firmId).list(),
          );
          expect(bills, hasLength(1));
          final lines = await tester.runAsync(
            () => db.purchaseRepositoryFor(firmId).itemsFor(bills!.single.id),
          );
          expect(lines!.single.name, 'Blue Notebook');
          expect(lines.single.rate, 60);
          container
              .read(appRouterProvider)
              .push('/purchase/edit/${bills!.single.id}');
        } else {
          final docs = await tester.runAsync(
            () => db.salesRepositoryFor(firmId).list(),
          );
          expect(docs, hasLength(1));
          final lines = await tester.runAsync(
            () => db.salesRepositoryFor(firmId).itemsFor(docs!.single.id),
          );
          expect(lines!.single.name, 'Blue Notebook');
          expect(lines.single.rate, 100);
          container
              .read(appRouterProvider)
              .push('/sales/edit/${docs!.single.id}');
        }
        await frames(tester, count: 20);
        expect(find.widgetWithText(TextField, 'Blue Notebook'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await close(tester);
      },
    );
  }

  testWidgets(
    'mobile required customer and product validation cannot be bypassed',
    (tester) async {
      await boot(tester);
      await tester.tap(find.text('Invoice'));
      await frames(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Save and close'));
      await frames(tester);
      expect(find.text('Please select a customer'), findsOneWidget);
      expect(
        await tester.runAsync(() => db.salesRepositoryFor(firmId).list()),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'mobile bank section saves actual settings and preserves other firm fields',
    (tester) async {
      await boot(tester);
      final before = await tester.runAsync(
        () => db.firmRepository.getById(firmId),
      );
      container.read(appRouterProvider).push('/settings/firm?section=bank');
      await frames(tester);
      expect(find.text('Bank Details'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Bank name'),
        'Test Bank',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
      await frames(tester, count: 20);
      final after = await tester.runAsync(
        () => db.firmRepository.getById(firmId),
      );
      expect(after!.bankName, 'Test Bank');
      expect(after.name, before!.name);
      expect(after.invoicePrefix, before.invoicePrefix);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('mobile business menu switches actual books', (tester) async {
    await boot(tester, secondFirm: true);
    await frames(tester);
    await tester.tap(find.byTooltip('Switch business'));
    await frames(tester);
    await tester.tap(find.text('Second Business'));
    await frames(tester);
    expect(container.read(activeFirmIdProvider), secondFirmId);
    expect(find.text('Second Business'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('party tabs accurately distinguish all customers and vendors', (
    tester,
  ) async {
    await boot(tester);
    container.read(appRouterProvider).go('/parties');
    await frames(tester);
    expect(find.text('Acme Customer'), findsOneWidget);
    expect(find.text('Acme Supplier'), findsOneWidget);
    await tester.tap(find.text('Customers'));
    await frames(tester);
    expect(find.text('Acme Customer'), findsOneWidget);
    expect(find.text('Acme Supplier'), findsNothing);
    await tester.tap(find.text('Vendors'));
    await frames(tester);
    expect(find.text('Acme Supplier'), findsOneWidget);
    expect(find.text('Acme Customer'), findsNothing);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('Android system back retraces sections and document types', (
    tester,
  ) async {
    await boot(tester);
    final router = container.read(appRouterProvider);
    for (final path in ['/sales', '/items', '/sales?type=quotation']) {
      router.go(path);
      await frames(tester);
    }
    for (final path in ['/items', '/sales', '/dashboard']) {
      await tester.binding.handlePopRoute();
      await frames(tester);
      expect(router.routeInformationProvider.value.uri.toString(), path);
      expect(tester.takeException(), isNull);
    }
    await close(tester);
  });

  testWidgets(
    'Android back closes an overlay before navigating and pops editors first',
    (tester) async {
      await boot(tester);
      final router = container.read(appRouterProvider);
      router.go('/sales');
      await frames(tester);
      router.go('/items');
      await frames(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('More'),
        ),
      );
      await frames(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.binding.handlePopRoute();
      await frames(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(router.routeInformationProvider.value.uri.path, '/items');
      router.push('/items/new');
      await frames(tester);
      await tester.binding.handlePopRoute();
      await frames(tester);
      expect(router.routeInformationProvider.value.uri.path, '/items');
      await tester.binding.handlePopRoute();
      await frames(tester);
      expect(router.routeInformationProvider.value.uri.path, '/sales');
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'Android back from counter opened with go returns to its previous section',
    (tester) async {
      await boot(tester);
      final router = container.read(appRouterProvider);
      router.go('/items');
      await frames(tester);
      router.go('/pos');
      await frames(tester);
      await tester.binding.handlePopRoute();
      await frames(tester);
      expect(router.routeInformationProvider.value.uri.path, '/items');
      await tester.binding.handlePopRoute();
      await frames(tester);
      expect(router.routeInformationProvider.value.uri.path, '/dashboard');
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('Android back keeps unsaved invoice confirmation intact', (
    tester,
  ) async {
    await boot(tester);
    final router = container.read(appRouterProvider);
    router.go('/sales');
    await frames(tester);
    router.push('/sales/new');
    await frames(tester);
    await tester.tap(find.text('Select Customer'));
    await frames(tester);
    await tester.tap(find.text('Acme Customer'));
    await frames(tester);
    await tester.binding.handlePopRoute();
    await frames(tester);
    expect(find.text('Keep editing'), findsOneWidget);
    expect(router.canPop(), isTrue);
    expect(find.text('Acme Customer'), findsWidgets);
    await tester.tap(find.text('Keep editing'));
    await frames(tester);
    expect(router.canPop(), isTrue);
    expect(find.text('Acme Customer'), findsWidgets);
    await tester.binding.handlePopRoute();
    await frames(tester);
    await tester.tap(find.text('Discard'));
    await frames(tester);
    expect(router.routeInformationProvider.value.uri.path, '/sales');
    await tester.binding.handlePopRoute();
    await frames(tester);
    expect(router.routeInformationProvider.value.uri.path, '/dashboard');
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets(
    'Android predictive back stays in Flutter while section history exists',
    (tester) async {
      await boot(tester);
      final platformCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          platformCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final router = container.read(appRouterProvider);
      router.go('/items');
      await frames(tester);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      app.onNavigationNotification!(
        const NavigationNotification(canHandlePop: false),
      );
      await frames(tester);
      expect(
        platformCalls
            .lastWhere(
              (call) =>
                  call.method == 'SystemNavigator.setFrameworkHandlesBack',
            )
            .arguments,
        true,
      );
      await tester.binding.handlePopRoute();
      await frames(tester);
      expect(router.routeInformationProvider.value.uri.path, '/dashboard');
      expect(
        platformCalls.where((call) => call.method == 'SystemNavigator.pop'),
        isEmpty,
      );
      app.onNavigationNotification!(
        const NavigationNotification(canHandlePop: false),
      );
      await frames(tester);
      expect(
        platformCalls
            .lastWhere(
              (call) =>
                  call.method == 'SystemNavigator.setFrameworkHandlesBack',
            )
            .arguments,
        false,
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('mobile full amount remains readable at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.mobile(),
        home: Scaffold(
          body: SizedBox(
            width: 90,
            child: MobileAmount(Decimal.fromInt(12345678)),
          ),
        ),
      ),
    );
    expect(find.text('₹1,23,45,678.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> frames(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}
