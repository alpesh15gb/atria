import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/features/sales/sale_detail_screen.dart';
import 'package:atria/features/sales/sales_list_screen.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final detail in [false, true]) {
    testWidgets(
      'switching business clears the previous ${detail ? 'invoice detail' : 'invoice list'}',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = AppDatabase.test(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
        );
        final first = await db.firmRepository.create(name: 'First');
        final second = await db.firmRepository.create(name: 'Second');
        for (final firm in [first, second]) {
          await db
              .salesRepositoryFor(firm.id)
              .save(
                SalesDraft(
                  id: firm.id,
                  number: 'INV-${firm.name}',
                  docType: 'invoice',
                  invoiceDate: DateTime.now(),
                  lines: [
                    SalesLineDraft(
                      id: '${firm.id}-line',
                      name: 'Goods',
                      quantity: Decimal.one,
                      unit: 'pcs',
                      rate: Decimal.fromInt(100),
                      gstRate: 18,
                    ),
                  ],
                ),
              );
        }
        await container.read(activeFirmIdProvider.notifier).select(first.id);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: ThemeData(platform: TargetPlatform.windows),
              home: detail
                  ? SaleDetailScreen(id: first.id)
                  : const SalesListScreen(),
            ),
          ),
        );
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('INV-First'), findsWidgets);
        await container.read(activeFirmIdProvider.notifier).select(second.id);
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('INV-First'), findsNothing);
        expect(
          find.text(detail ? 'Invoice not found' : 'INV-Second'),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        await db.close();
      },
    );
  }
}
