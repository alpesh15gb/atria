import 'dart:io';
import 'dart:ui' as ui;

import 'package:atria/app.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/router/app_router.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/shared/widgets/unsaved_guard.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  Future<void> boot(
    WidgetTester tester,
    TargetPlatform platform,
    Size size,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    PackageInfo.setMockInitialValues(
      appName: 'Apex Books',
      packageName: 'in.apexbooks.app',
      version: '1',
      buildNumber: '1',
      buildSignature: '',
    );
    for (final e in {
      'Inter': 'Inter[opsz,wght].ttf',
      'Manrope': 'Manrope.ttf',
      'Hanken Grotesk': 'HankenGrotesk.ttf',
    }.entries) {
      await (FontLoader(
        e.key,
      )..addFont(rootBundle.load('assets/fonts/${e.value}'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final style in ['Regular', 'Fill']) {
      await (FontLoader('packages/phosphor_flutter/Phosphor$style')..addFont(
            rootBundle.load(
              'packages/phosphor_flutter/lib/fonts/Phosphor${style == 'Regular' ? '' : '-Fill'}.ttf',
            ),
          ))
          .load();
    }
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(
      name: 'Independent Audit Business',
      stateCode: '29',
    );
    await db
        .partyRepositoryFor(firm.id)
        .create(name: 'Audit Customer', type: 'customer');
    await db
        .itemRepositoryFor(firm.id)
        .create(
          name: 'Audit Notebook',
          sku: 'AUDIT-001',
          salePrice: 100,
          openingStock: 10,
        );
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
    await container.read(onboardingDoneProvider.notifier).complete();
    await container.read(appInitializationProvider.future);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: UncontrolledProviderScope(
          container: container,
          child: const AtriaApp(),
        ),
      ),
    );
    await frames(tester);
    container.read(appRouterProvider).go('/dashboard');
    await frames(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await frames(tester);
    await db.close();
    debugDefaultTargetPlatformOverride = null;
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final render = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture')),
      );
      final img = await render.toImage(pixelRatio: 1);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      await File('build/import-audit/repairs-2026-10-11/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      img.dispose();
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'REPAIRED ${platform.name}: typing alone arms item/party guard',
      (tester) async {
        await boot(
          tester,
          platform,
          platform == TargetPlatform.android
              ? const Size(412, 892)
              : const Size(1280, 800),
        );
        final router = container.read(appRouterProvider);
        for (final route in ['/items/new', '/parties/new']) {
          router.go(route.split('/new').first);
          await frames(tester);
          router.push(route);
          await frames(tester);
          final field = find.byWidgetPredicate(
            (w) =>
                w is TextField &&
                (w.decoration?.labelText == 'Item name *' ||
                    w.decoration?.labelText == 'Party name *'),
          );
          expect(field, findsOneWidget);
          await tester.enterText(field, 'Unsaved audit input');
          await frames(tester);
          final guard = tester.widget<UnsavedGuard>(
            find.byType(UnsavedGuard).last,
          );
          expect(guard.hasChanges, true);
          await tester.binding.handlePopRoute();
          await frames(tester);
          expect(find.text('Keep editing'), findsOneWidget);
          await tester.tap(find.text('Discard'));
          await frames(tester);
          expect(find.text('Unsaved audit input'), findsNothing);
        }
        await close(tester);
      },
    );
    testWidgets('${platform.name}: independent scaled screen sweep', (
      tester,
    ) async {
      final mobile = platform == TargetPlatform.android;
      await boot(
        tester,
        platform,
        mobile ? const Size(360, 640) : const Size(1024, 600),
      );
      await container.read(interfaceScaleProvider.notifier).set(1.5);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final errors = <String>[];
      final old = FlutterError.onError;
      FlutterError.onError = (d) {
        errors.add(d.exceptionAsString());
      };
      try {
        for (final route in [
          '/dashboard',
          '/sales',
          '/purchase',
          '/items',
          '/parties',
          '/payments',
          '/expenses',
          '/reports',
          '/stock',
          '/settings',
          '/settings/bank-accounts',
          '/items/new',
          '/parties/new',
          '/sales/new',
          '/purchase/new',
          '/expenses/new',
          '/ledger/journals/new',
          '/pos',
        ]) {
          errors.clear();
          container.read(appRouterProvider).go(route);
          await frames(tester);
          if (errors.isNotEmpty) {
            await shot(tester, '${platform.name}-${route.replaceAll('/', '_')}');
          }
          expect(errors, isEmpty, reason: '${platform.name} $route layout');
          if (route == '/pos') await shot(tester, '${platform.name}-pos-scaled');
        }
      } finally {
        FlutterError.onError = old;
      }
      await close(tester);
    });
  }
  testWidgets('Android POS back protects the active cart', (tester) async {
    await boot(tester, TargetPlatform.android, const Size(412, 892));
    final router = container.read(appRouterProvider);
    router.go('/pos');
    await frames(tester);
    final search = find.byType(TextField).first;
    await tester.enterText(search, 'AUDIT-001');
    await frames(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await frames(tester);
    await shot(tester, 'android-pos-before-back');
    expect(find.text('Audit Notebook'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await frames(tester);
    expect(find.text('Keep editing'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await frames(tester);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/pos');
    expect(find.text('Audit Notebook'), findsOneWidget);
    tester.view.physicalSize = const Size(360, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await container.read(interfaceScaleProvider.notifier).set(1.5);
    await frames(tester);
    expect(tester.takeException(), isNull);
    await shot(tester, 'android-pos-populated-scaled');
    await close(tester);
  });
  testWidgets('Android stock adjustment dialog with keyboard', (tester) async {
    await boot(tester, TargetPlatform.android, const Size(360, 640));
    container.read(appRouterProvider).go('/stock');
    await frames(tester);
    await tester.tap(find.byTooltip('Adjust stock'));
    await frames(tester);
    final errors = <String>[];
    final old = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString());
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await frames(tester);
    expect(errors, isEmpty);
    await shot(tester, 'android-stock-keyboard');
    tester.view.viewInsets = const FakeViewPadding();
    await frames(tester);
    FlutterError.onError = old;
    await close(tester);
  });
}
