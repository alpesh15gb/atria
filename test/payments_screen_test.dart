import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/payments/payments_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regressions for the Payments screen.
///
/// - The summary cards stored their value in a `dynamic` field, so
///   `Formatters.money(...)` performed an implicit `Decimal` -> `num` cast at
///   runtime and every card rendered as the red "type 'Decimal' is not a
///   subtype of type 'num'" error box. The cards must render real money text.
/// - The row kebab menu must soft-delete into the recycle bin, never
///   hard-delete (payments are audit-locked documents).
///
/// The fixture payments are dated **now** rather than a fixed day. The screen's
/// summary and list default to the current month, so hard-coded dates made this
/// file pass all month and then fail at midnight on the 1st, when the data slid
/// into "last month" — a test that breaks with the calendar is worse than no
/// test, because the failure looks like a regression in the screen.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  testWidgets('summary cards render money, not error boxes', (tester) async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );

    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    final firmId = firm.id;
    await container.read(activeFirmIdProvider.notifier).select(firmId);

    final payments = db.paymentRepositoryFor(firmId);
    await payments.create(
      type: 'payment_in',
      number: 'PIN-001',
      partyName: 'Keystone Infra Pvt Ltd',
      amount: 1330,
      date: DateTime.now(),
      mode: 'cash',
    );
    await payments.create(
      type: 'payment_out',
      number: 'POUT-001',
      partyName: 'Sharma Electric Works',
      amount: 4500,
      date: DateTime.now(),
      mode: 'bank',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: PaymentsScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull,
        reason: 'No card may render as an error box');
    expect(find.text('Cash in hand'), findsOneWidget);
    expect(find.text('Bank accounts'), findsOneWidget);
    expect(find.text('Cheques to deposit'), findsOneWidget);
    expect(find.text('₹1,330.00'), findsOneWidget);
    expect(find.text('− ₹4,500.00'), findsOneWidget);
    expect(find.textContaining('PIN-001'), findsOneWidget);
    expect(find.textContaining('POUT-001'), findsOneWidget);

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

  testWidgets('row kebab menu soft-deletes into the recycle bin',
      (tester) async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );

    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    final firmId = firm.id;
    await container.read(activeFirmIdProvider.notifier).select(firmId);

    final payments = db.paymentRepositoryFor(firmId);
    final payment = await payments.create(
      type: 'payment_in',
      number: 'PIN-001',
      partyName: 'Keystone Infra Pvt Ltd',
      amount: 1330,
      date: DateTime.now(),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: PaymentsScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('PIN-001'), findsOneWidget);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(await payments.list(), isEmpty,
        reason: 'The payment must leave the live list immediately');
    final row = await payments.getById(payment.id);
    expect(row!.isDeleted, isTrue,
        reason: 'A kebab delete must soft-delete into the recycle bin, never '
            'hard-delete an audit-locked document');

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
