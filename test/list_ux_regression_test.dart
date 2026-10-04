import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/expenses/expenses_screen.dart';
import 'package:atria/features/sales/sales_list_screen.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regressions for two list-screen bugs found in the app-wide swipe.
///
/// * **Expenses search matched everything.** The digit-stripped query was
///   compared against the raw amount string without first checking that the
///   stripped query was non-empty, and `String.contains('')` is true for every
///   string — so any text query without digits returned every row and
///   "No matches" was unreachable.
/// * **The sales Status column always read "Confirmed".** Every saved invoice
///   is stored `status == 'confirmed'`, so the column printed the same word on
///   a settled invoice and on an overdue one, and Paid / Partial / Unpaid were
///   never visible. Invoices must fall back to their payment state.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  Future<(AppDatabase, ProviderContainer, String)> boot() async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
    return (db, container, firm.id);
  }

  Future<void> teardown(
    WidgetTester tester,
    AppDatabase db,
    ProviderContainer container,
  ) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  }

  testWidgets('an expenses text search that matches nothing says so',
      (tester) async {
    final (db, container, firmId) = await boot();
    await db.expenseRepositoryFor(firmId).create(
          type: 'expense',
          number: 'EXP-001',
          category: 'rent',
          amount: 18000,
          date: DateTime.now(),
          mode: 'cash',
          vendorName: 'Landlord',
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: ExpensesScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Landlord'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('No matches'), findsWidgets,
        reason: 'a query with no digits must not fall through to the numeric '
            'branch and match every row');
    expect(find.textContaining('Landlord'), findsNothing);

    await teardown(tester, db, container);
  }, timeout: timeout);

  testWidgets('an unpaid invoice shows its payment state, not "Confirmed"',
      (tester) async {
    final (db, container, firmId) = await boot();
    await db.salesRepositoryFor(firmId).save(SalesDraft(
          id: 'inv-1',
          number: 'INV-001',
          docType: 'invoice',
          invoiceDate: DateTime.now(),
          lines: [
            SalesLineDraft(
              id: 'l1',
              name: 'Consulting',
              quantity: Decimal.fromInt(1),
              unit: 'svc',
              rate: Decimal.fromInt(1000),
              gstRate: 18,
            ),
          ],
          partyName: 'Keystone Infra Pvt Ltd',
        ));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SalesListScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('Unpaid'), findsWidgets,
        reason: 'the Status column carries the payment state for invoices');
    expect(find.text('Confirmed'), findsNothing,
        reason: '"Confirmed" is the stored default of every invoice, so it '
            'told the reader nothing and hid Paid / Partial / Unpaid');

    await teardown(tester, db, container);
  }, timeout: timeout);
}
