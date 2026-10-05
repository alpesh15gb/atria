import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/engine/gst_engine.dart';
import 'package:atria/core/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/core/theme/app_typography.dart';
import 'package:atria/features/parties/party_statement_screen.dart';
import 'package:atria/features/parties/statement_of_account_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The statement ledger has to hold a real running balance at phone width.

/// Both ledger screens share a 4/3/3/4 flex row whose Balance column is ~91dp
/// at 360dp. A running balance crosses a crore routinely, and the full
/// "₹1,00,00,000.00" is ~99dp — it painted across the Credit column. This
/// seeds enough history to produce a large balance and asks whether the row
/// still lays out.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  Future<void> loadAppFont() async {
    final loader = FontLoader(AppTypography.family);
    loader.addFont(rootBundle.load('assets/fonts/Inter[opsz,wght].ttf'));
    loader.addFont(rootBundle.load('assets/fonts/Inter-Italic[opsz,wght].ttf'));
    await loader.load();
  }

  Future<(AppDatabase, ProviderContainer, String)> seed() async {
    await loadAppFont();
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Apex Traders');
    await container.read(activeFirmIdProvider.notifier).ready;
    await container.read(activeFirmIdProvider.notifier).select(firm.id);

    final parties = db.partyRepositoryFor(firm.id);
    final party = await parties.create(name: 'Keystone Infra Pvt Ltd');
    final sales = db.salesRepositoryFor(firm.id);

    // A crore of invoiced sales against the one party, so the running balance
    // is a number the narrow column has to work to hold.
    for (var i = 0; i < 40; i++) {
      await sales.save(
        SalesDraft(
          id: 'inv_$i',
          number: 'INV/2026/${(i + 1).toString().padLeft(3, '0')}',
          docType: 'invoice',
          partyId: party.id,
          partyName: party.name,
          invoiceDate: DateTime(2026, 1, 5 + i),
          dueDate: DateTime(2026, 2, 5 + i),
          status: 'confirmed',
          lines: [
            SalesLineDraft(
              id: 'ln_${i}_1',
              name: 'Consulting',
              quantity: Decimal.one,
              unit: 'Nos',
              rate: Decimal.fromInt(250000),
              gstRate: 0,
              cessRate: 0,
              taxMode: TaxMode.exclusive,
            ),
          ],
          applyRoundOff: false,
          sequence: i,
        ),
      );
    }

    return (db, container, party.id);
  }

  Future<void> dispose(
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

  for (final screen in [
    (
      'party statement',
      (String partyId) => PartyStatementScreen(partyId: partyId),
    ),
    (
      'statement of account',
      (String partyId) => StatementOfAccountScreen(partyId: partyId),
    ),
  ]) {
    testWidgets(
      '${screen.$1} holds a crore balance at 360dp',
      timeout: timeout,
      (tester) async {
        final (db, container, partyId) = await seed();

        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              // The name says "at 360dp" and the width delivers that. The
              // platform is declared because the ledger and grid now choose
              // their layout by platform as well: a 360dp window on the desktop
              // surface is a squeezed desktop, which is a different claim.
              theme: AppTheme.light().copyWith(platform: TargetPlatform.android),
              home: Scaffold(body: screen.$2(partyId)),
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        // The screen opens on "This Month", which is empty for a January seed,
        // so only a brought-forward row would ever render. All Time is what
        // puts forty invoices in the column.
        await tester.tap(find.text('All Time'));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        // The crore balance is on the fortieth row, well below the fold. Only
        // built rows have text to find, so the list has to be scrolled to the
        // end before the assertion means anything.
        //
        // Scoped to the ledger, not `find.byType(Scrollable)`: this screen's
        // party picker is a `DropdownButtonFormField`, whose button owns a
        // *horizontal* scroll view, so a bare `Scrollable` finder matches two
        // widgets here and `drag` throws "expected exactly one".
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        final error = tester.takeException();

        // The running balance is a crore. The Balance column is ~91dp at 360dp
        // while the full "₹1,00,00,000.00" is ~99dp, and a money string is one
        // unbreakable word — so the exact form does not overflow loudly, it
        // paints silently across the Credit column, and takeException cannot
        // see it. Asserting on the rendered text is what guards the compact
        // form.
        expect(
          find.text('₹1 Cr'),
          findsWidgets,
          reason:
              '${screen.$1} ledger Balance column must render the running '
              'balance compactly at 360dp; the exact form paints across the '
              'Credit column',
        );

        await dispose(tester, db, container);
        expect(
          error,
          isNull,
          reason:
              '${screen.$1} overflows with a real running balance at '
              '360dp',
        );
      },
    );
  }
}
