import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/core/theme/app_typography.dart';
import 'package:atria/features/payments/payments_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Payments screen's "Cash in hand" card and the ledger's Cash account are
/// the same number to a user — both are labelled "Cash in hand". They have to
/// be computed the same way, or the first question about a discrepancy has no
/// answer.
///
/// The card used to sum the payment rows alone. The ledger's cash account also
/// receives cash expenses (paying wages in cash is money leaving the till) and
/// hand-keyed vouchers. The two disagreed by exactly that.

void main() {
  const timeout = Timeout(Duration(minutes: 2));

  Future<void> loadAppFont() async {
    final loader = FontLoader(AppTypography.family);
    loader.addFont(rootBundle.load('assets/fonts/Inter[opsz,wght].ttf'));
    loader.addFont(rootBundle.load('assets/fonts/Inter-Italic[opsz,wght].ttf'));
    await loader.load();
  }

  testWidgets('the cash card agrees with the ledger after a cash expense',
      timeout: timeout, (tester) async {
    await loadAppFont();
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Apex Traders');
    await container.read(activeFirmIdProvider.notifier).ready;
    await container.read(activeFirmIdProvider.notifier).select(firm.id);

    // Money into the till: a ₹10,000 cash receipt.
    await db.paymentRepositoryFor(firm.id).create(
          type: 'payment_in',
          number: 'R-1',
          amount: 10000,
          date: DateTime(2026, 4, 2),
          mode: 'cash',
        );
    // Money out of the till that never touches the payments table: ₹3,000
    // paid in cash for carriage.
    await db.expenseRepositoryFor(firm.id).create(
          type: 'expense',
          number: 'EXP-1',
          category: 'Carriage',
          amount: 3000,
          date: DateTime(2026, 4, 3),
          mode: 'cash',
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PaymentsScreen(),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The balance provider derives the cards from the trial balance, which is
    // an async re-read of every document table; pump until it has emitted
    // rather than settling, which can stop before the stream ticks.
    for (var i = 0;
        i < 40 &&
            !tester.widgetList<Text>(find.byType(Text)).any(
                (t) => t.data != null && t.data!.contains('7,000'));
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // What the ledger says about cash: 10,000 in, 3,000 out, ₹7,000 in hand.
    final ledgerRepo = db.ledgerRepositoryFor(firm.id);
    await ledgerRepo.ensureChart();
    final cash = await ledgerRepo.byCode(LedgerCodes.cash);
    final cashLedger = await ledgerRepo.accountLedger(
      cash!.id,
      asOf: DateTime(2026, 12, 31),
    );
    expect(cashLedger.closing, 7000.0);

    // The card reads its figure from the same books. Before the fix it summed
    // the payments table alone and printed ₹10,000 — the till looked ₹3,000
    // richer than it was.
    //
    // Asserted on the rendered figure rather than the widget tree because the
    // card stacks its icon above the text below the compact breakpoint, so the
    // Row that carries the label is not the Row that carries the figure.
    expect(
      find.text('₹7,000.00'),
      findsWidgets,
      reason: 'the Payments cash card must agree with the ledger cash '
          'account; a cash expense leaves the till and the card has to '
          'show it leaving.',
    );

    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  });
}
