// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/app.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/router/app_router.dart';
import 'package:atria/core/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Stitch mobile screens use saved books across scales and themes', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Apex Books',
      packageName: 'in.apexbooks.app',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    tester.view.physicalSize = const Size(412, 892);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final entry in {
      'Inter': 'Inter[opsz,wght].ttf',
      'Manrope': 'Manrope.ttf',
      'Hanken Grotesk': 'HankenGrotesk.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load('assets/fonts/${entry.value}'))).load();
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
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(
      name: 'Apex Integrations',
      stateCode: '29',
      gstin: '29ABCDE1234F1Z5',
    );
    final customer = await db
        .partyRepositoryFor(firm.id)
        .create(name: 'Kalyan Enterprises', type: 'customer', stateCode: '29');
    final supplier = await db
        .partyRepositoryFor(firm.id)
        .create(
          name: 'Office Supply Company',
          type: 'supplier',
          stateCode: '29',
        );
    final item = await db
        .itemRepositoryFor(firm.id)
        .create(
          name: 'Blue Notebook',
          sku: 'BK-001',
          salePrice: 100,
          purchasePrice: 60,
          gstRate: 18,
          lowStockAlert: 5,
        );
    await db
        .itemRepositoryFor(firm.id)
        .create(
          name: 'Annual maintenance service',
          salePrice: 24000,
          isService: true,
        );
    await db
        .purchaseRepositoryFor(firm.id)
        .save(
          PurchaseDraft(
            id: 'audit-purchase',
            number: 'PUR-001',
            docType: 'bill',
            partyId: supplier.id,
            partyName: supplier.name,
            billDate: DateTime.now(),
            lines: [
              PurchaseLineDraft(
                id: 'audit-purchase-line',
                itemId: item.id,
                name: item.name,
                quantity: Decimal.fromInt(10),
                unit: 'pcs',
                rate: Decimal.fromInt(60),
                gstRate: 18,
              ),
            ],
          ),
        );
    await db
        .salesRepositoryFor(firm.id)
        .save(
          SalesDraft(
            id: 'audit-invoice',
            number: 'INV-001',
            docType: 'invoice',
            partyId: customer.id,
            partyName: customer.name,
            invoiceDate: DateTime.now(),
            lines: [
              SalesLineDraft(
                id: 'audit-sale-line',
                itemId: item.id,
                name: item.name,
                quantity: Decimal.fromInt(2),
                unit: 'pcs',
                rate: Decimal.fromInt(100),
                gstRate: 18,
              ),
            ],
          ),
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
    final router = container.read(appRouterProvider);
    for (final size in [const Size(412, 892), const Size(360, 640)]) {
      tester.view.physicalSize = size;
      for (final scale in [1.0, 1.3, .85]) {
        await container.read(interfaceScaleProvider.notifier).set(scale);
        for (final path in [
          '/dashboard',
          '/sales',
          '/purchase',
          '/items',
          '/parties',
          '/reports',
          '/payments',
          '/expenses',
          '/settings',
          '/sales/new',
          '/purchase/new',
          '/items/new',
          '/parties/new',
          '/expenses/new',
          '/pos',
        ]) {
          debugPrint('AUDIT $path $size $scale');
          router.go(path);
          await frames(tester);
          expect(
            tester.takeException(),
            isNull,
            reason: '$path at $size, scale $scale',
          );
          if (size.width == 412 && scale == 1.0) {
            await capture(tester, path.replaceAll('/', '-'));
          }
        }
      }
    }
    tester.view.physicalSize = const Size(412, 892);
    await container.read(interfaceScaleProvider.notifier).set(1);
    router.go('/pos');
    await frames(tester);
    await tester.enterText(find.byType(TextField).first, 'BK-001');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await frames(tester);
    expect(find.text('Blue Notebook'), findsOneWidget);
    await capture(tester, 'pos-cart');
    await tester.tap(find.text('Review payment'));
    await frames(tester);
    for (final size in [const Size(360, 640), const Size(412, 892)]) {
      tester.view.physicalSize = size;
      for (final scale in [1.3, .85, 1.0]) {
        await container.read(interfaceScaleProvider.notifier).set(scale);
        await frames(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: 'checkout at $size, scale $scale',
        );
      }
    }
    final complete = find.widgetWithText(FilledButton, 'Complete sale');
    await tester.ensureVisible(complete);
    await frames(tester);
    await capture(tester, 'pos-payment');
    await tester.tap(complete);
    await frames(tester);
    final invoices = await tester.runAsync(
      () => db.salesRepositoryFor(firm.id).list(),
    );
    expect(invoices, hasLength(2));
    final stock = await tester.runAsync(
      () => db.itemRepositoryFor(firm.id).getById(item.id),
    );
    expect(stock!.currentStock, 7);
    expect(tester.takeException(), isNull);
    await container.read(themeModeProvider.notifier).set(ThemeMode.dark);
    router.go('/dashboard');
    await frames(tester);
    await capture(tester, 'dashboard-dark');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await frames(tester);
    await db.close();
  });
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/import-audit/stitch-mobile');
    await dir.create(recursive: true);
    await File('${dir.path}/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}
