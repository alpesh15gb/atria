import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/purchase/purchase_editor_screen.dart';
import 'package:atria/shared/widgets/atria_line_grid.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opening a *saved* purchase bill must bring its lines back.
///
/// A purchase bill has no read-only detail screen — `purchase_list_screen`
/// opens the editor, so the editor's reload path is the only place a saved
/// bill's items can be seen at all. That makes it worth its own test: the
/// repository round-trip is covered elsewhere, but nothing pinned the screen,
/// and a bill that reloads with a single blank line looks exactly like a bill
/// whose lines were lost.
///
/// The blank line is the tell. A freshly constructed line defaults to quantity
/// 1 and an empty rate, so a row showing `1` and a zero amount next to no name
/// means the reload produced no lines and the grid fell back to its empty
/// state — not that the stored data was empty.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  late AppDatabase db;
  late ProviderContainer container;

  Future<void> boot() async {
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(
      name: 'Mahaveer Computers',
      stateCode: '27',
    );
    await container.read(activeFirmIdProvider.notifier).select(firm.id);

    await db.purchaseRepositoryFor(firm.id).save(PurchaseDraft(
      id: 'bill-1',
      number: 'MC2025-26/7164',
      docType: 'bill',
      billDate: DateTime(2026, 3, 27),
      lines: [
        PurchaseLineDraft(
          id: 'line-1',
          name: 'Laptop Charger 65W',
          hsn: '8504',
          quantity: Decimal.fromInt(2),
          unit: 'pcs',
          rate: Decimal.fromInt(450),
          gstRate: 18,
        ),
        PurchaseLineDraft(
          id: 'line-2',
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

  Future<void> open(WidgetTester tester, {required Size size}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PurchaseEditorScreen(editId: 'bill-1'),
        ),
      ),
    );
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> teardown(WidgetTester tester) async {
    // Unmount before disposing, so drift's stream teardown runs inside this
    // test's fake async; see editor_layout_regression_test for why.
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await db.close();
  }

  testWidgets('a saved bill reopens with its lines, on a desktop window',
      (tester) async {
    await boot();
    await open(tester, size: const Size(1680, 1000));

    expect(find.byType(AtriaLineGrid), findsOneWidget);
    // Both stored lines, by name — the header fields were already known to
    // reload, so the lines are what is being pinned here.
    expect(find.text('Laptop Charger 65W'), findsOneWidget);
    expect(find.text('USB-C Cable 1m'), findsOneWidget);
    // Their HSNs too: a name that rendered against a blank rate would still
    // pass the check above, and that is exactly the row the bug produced.
    expect(find.text('8504'), findsWidgets);
    expect(find.text('8544'), findsWidgets);

    await teardown(tester);
  }, timeout: timeout);

  testWidgets('a saved bill reopens with its lines on a phone',
      (tester) async {
    await boot();
    await open(tester, size: const Size(360, 900));

    expect(find.byType(AtriaLineGrid), findsOneWidget);
    expect(find.text('Laptop Charger 65W'), findsOneWidget);
    expect(find.text('USB-C Cable 1m'), findsOneWidget);
    expect(find.text('8504'), findsWidgets);
    expect(find.text('8544'), findsWidgets);

    await teardown(tester);
  }, timeout: timeout);
}