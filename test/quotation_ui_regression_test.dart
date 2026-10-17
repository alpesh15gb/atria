import 'package:atria/app.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/router/app_router.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/shared/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('fitted money still paints its figure on narrow layouts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 70,
            child: MoneyText(Decimal.parse('27977'), shrinkToFit: true),
          ),
        ),
      ),
    );
    expect(find.textContaining('27,977'), findsOneWidget);
    expect(tester.getSize(find.byType(FittedBox)).width, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'real conversion route loads quotation rows and edit preserves saved tax despite changed master',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase.test(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      final firm = (await db.firmRepository.create(
        name: 'Apex',
        gstin: '36CZFPM0045M2Z7',
        stateCode: '36',
      )).id;
      final party = await db
          .partyRepositoryFor(firm)
          .create(name: 'Keystone Infra', type: 'customer', stateCode: '36');
      final item = await db
          .itemRepositoryFor(firm)
          .create(name: 'Saved Camera', gstRate: 0, salePrice: 999);
      final doc = await db
          .salesRepositoryFor(firm)
          .save(
            SalesDraft(
              id: 'q',
              number: 'Q-25',
              docType: 'quotation',
              partyId: party.id,
              partyName: party.name,
              invoiceDate: DateTime(2026, 10, 9),
              lines: [
                SalesLineDraft(
                  id: 'l',
                  itemId: item.id,
                  name: 'Saved Camera',
                  quantity: Decimal.fromInt(9),
                  unit: 'pcs',
                  rate: Decimal.parse('4000.1234'),
                  gstRate: 18,
                ),
              ],
            ),
          );
      await container.read(activeFirmIdProvider.notifier).select(firm);
      await container.read(onboardingDoneProvider.notifier).complete();
      await container.read(appInitializationProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const AtriaApp(),
        ),
      );
      await frames(tester);
      final router = container.read(appRouterProvider);
      router.go('/sales');
      await frames(tester);
      router.push('/sales/new?type=invoice&convertFrom=q');
      await frames(tester);
      final values = tester
          .widgetList<TextField>(find.byType(TextField))
          .map((w) => w.controller?.text)
          .toList();
      expect(values, contains('Saved Camera'));
      expect(values, contains('4000.1234'));
      router.pop();
      await frames(tester);
      router.push('/sales/edit/q?type=quotation');
      await frames(tester);
      await tester.tap(find.text('Save and close').first);
      await frames(tester);
      final saved = (await db.salesRepositoryFor(firm).getById('q'))!;
      expect(saved.grandTotal, closeTo(doc.grandTotal, .001));
      expect(
        (await db.salesRepositoryFor(firm).itemsFor('q')).single.gstRate,
        18,
      );
      expect(saved.balanceDue, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await frames(tester);
      await db.close();
    },
  );
}
