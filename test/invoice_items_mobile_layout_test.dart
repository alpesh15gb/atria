import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/features/sales/sale_detail_screen.dart';
import 'package:atria/shared/widgets/atria_line_grid.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A saved invoice's line items must be readable on a phone.
///
/// The Items card was the one place in the app that did not use the shared
/// responsive line grid — it built a `DataTable` instead, wrapped in a
/// horizontal scroller. Nine columns need roughly 800dp, so on a 360dp screen
/// the reader saw the item name and nothing else: rate, taxable value, the tax
/// columns and the line amount were all off to the right. Windows was fine
/// because a desktop window is wide enough to hold the whole table, which is
/// why the bug only ever appeared on Android.
///
/// These tests pin the property, not the widget choice: every figure a line
/// shows has to be inside the window it is being read in.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  late AppDatabase db;
  late ProviderContainer container;

  Future<void> boot() async {
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(gstin: '29ABCDE1234F1Z5', 
      name: 'Mahaveer Computers',
      stateCode: '27',
    );
    await container.read(activeFirmIdProvider.notifier).select(firm.id);

    await db.salesRepositoryFor(firm.id).save(SalesDraft(
      id: 'inv-1',
      number: 'MC2025-26/0416',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 3, 27),
      status: 'confirmed',
      placeOfSupply: '27',
      isInterState: false,
      lines: [
        SalesLineDraft(
          id: 'l1',
          name: 'Laptop Charger 65W',
          hsn: '8504',
          quantity: Decimal.fromInt(2),
          unit: 'pcs',
          rate: Decimal.fromInt(450),
          gstRate: 18,
        ),
        SalesLineDraft(
          id: 'l2',
          name: 'USB-C Cable 1m',
          hsn: '8544',
          quantity: Decimal.fromInt(5),
          unit: 'pcs',
          rate: Decimal.fromInt(120),
          gstRate: 18,
        ),
      ],
    ));
  }

  Future<void> mount(
      WidgetTester tester,
      Size size, {
      TargetPlatform platform = TargetPlatform.windows,
    }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    // The platform is declared because the grid chooses sheet-vs-cards by
    // platform, and `flutter test` defaults to android: a desktop-window test
    // left implicit would be asserting against the phone card layout.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: platform),
          home: const SaleDetailScreen(id: 'inv-1'),
        ),
      ),
    );
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> teardown(WidgetTester tester) async {
    // Unmount before disposing so drift's stream-teardown timers fire inside
    // this test's fake async; see the note in editor_layout_regression_test.
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await db.close();
  }

  testWidgets('every line figure is on screen on a phone',
      (tester) async {
    await boot();
    await mount(tester, const Size(360, 900));

    final grid = find.byType(AtriaLineGrid);
    expect(grid, findsOneWidget,
        reason: 'the Items card must use the shared responsive grid');

    // The old DataTable hid the numbers in a horizontal scroller: they were
    // built, laid out to the right of the window, and simply not readable.
    expect(find.byType(DataTable), findsNothing);

    // Matched by element identity, not by text: the stacked card repeats each
    // label once per line, so a `find.text('HSN')` lookup is ambiguous and a
    // value-only lookup would silently check just the first match.
    final offscreen = <String>[];
    for (final element
        in find.descendant(of: grid, matching: find.byType(Text)).evaluate()) {
      final value = (element.widget as Text).data;
      if (value == null || value.trim().isEmpty) continue;
      final rect = tester.getRect(find.byElementPredicate((e) => e == element));
      if (rect.left < -0.5 || rect.right > 360.5) {
        offscreen.add('"$value" at ${rect.left.toStringAsFixed(0)}..'
            '${rect.right.toStringAsFixed(0)}');
      }
    }

    expect(
      offscreen,
      isEmpty,
      reason: 'a phone-width reader must not have to scroll sideways to '
          'read a line, but these figures sit outside the window: '
          '${offscreen.join(', ')}',
    );

    // And the figures that matter are actually present.
    expect(find.text('Laptop Charger 65W'), findsWidgets);
    expect(find.text('USB-C Cable 1m'), findsWidgets);

    await teardown(tester);
  }, timeout: timeout);

  testWidgets('the same line keeps its full column set on a desktop window',
      (tester) async {
    await boot();
    await mount(tester, const Size(1680, 1000));

    final grid = find.byType(AtriaLineGrid);
    expect(grid, findsOneWidget);

    // Wide keeps the spreadsheet sheet, so the headings are still headers.
    for (final heading in ['Item', 'HSN', 'Qty', 'Rate', 'CGST', 'Amount']) {
      expect(find.text(heading), findsWidgets,
          reason: 'the $heading column must survive on a wide window');
    }

    await teardown(tester);
  }, timeout: timeout);
}