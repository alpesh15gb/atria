import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/parties/parties_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cover for the desktop Parties master-detail (Vyapar reference: parties on
/// the left, the selected party's transactions on the right): tapping a party
/// row selects it for the right pane instead of only opening the action
/// sheet, and the pane lists that party's invoices.
///
/// Also pins the row's GSTIN + phone line: with a masked GSTIN and a formatted
/// phone the line overflowed the ~340px master pane by 22px (the yellow/black
/// stripes in the corner of the row).
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  testWidgets('desktop: tapping a party shows their transactions in the pane',
      (tester) async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );

    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    final firmId = firm.id;
    await container.read(activeFirmIdProvider.notifier).select(firmId);

    final parties = db.partyRepositoryFor(firmId);
    final customer = await parties.create(name: 'Keystone Infra Pvt Ltd');
    await parties.create(name: 'Crk And Associates', type: 'customer');

    final sales = db.salesRepositoryFor(firmId);
    await sales.save(
      SalesDraft(
        id: 'inv_test_1',
        number: 'INV-001',
        docType: 'invoice',
        partyId: customer.id,
        partyName: customer.name,
        invoiceDate: DateTime(2026, 9, 20),
        lines: const [],
      ),
    );

    // Wide surface → the master-detail layout engages (>= Breakpoints.medium).
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          home: const Scaffold(body: PartiesScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Prompt before any selection.
    expect(find.text('Select a party to see their transactions'),
        findsOneWidget);

    await tester.tap(find.text('Keystone Infra Pvt Ltd').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The pane header + the invoice, live from the stream.
    expect(find.text('Select a party to see their transactions'),
        findsNothing);
    expect(find.text('Keystone Infra Pvt Ltd'), findsWidgets);
    expect(find.text('INV-001'), findsOneWidget);

    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  }, timeout: timeout);

  testWidgets('party row with GSTIN and phone does not overflow the pane',
      (tester) async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );

    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    final firmId = firm.id;
    await container.read(activeFirmIdProvider.notifier).select(firmId);

    await db.partyRepositoryFor(firmId).create(
          name: 'Keystone Infra Pvt Ltd',
          gstin: '29ABCDE1234F1Z5',
          phone: '919393646544',
        );

    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          home: const Scaffold(body: PartiesScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull,
        reason: 'The GSTIN + phone line must fit the master pane');
    expect(find.text('Keystone Infra Pvt Ltd'), findsOneWidget);

    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  }, timeout: timeout);
}
