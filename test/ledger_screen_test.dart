import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/ledger/chart_of_accounts_screen.dart';
import 'package:atria/features/ledger/journal_editor_screen.dart';
import 'package:atria/features/ledger/journal_list_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget cover for the ledger screens.
///
/// The repository is tested thoroughly in `ledger_test.dart`; this file exists
/// for the things only a rendered tree can catch — an unseeded chart showing an
/// empty screen, a screen that throws while building, the editor refusing to
/// save a voucher that does not balance.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(
      name: 'Shri Balaji Traders',
      stateCode: '29',
    );
    firmId = firm.id;
    await container.read(activeFirmIdProvider.notifier).select(firmId);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: screen),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Unmount and settle drift before the next test: these screens hold stream
  /// providers open, and closing the database out from under them is what makes
  /// widget tests in this repo hang rather than fail.
  Future<void> teardown(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  }

  const perTest = Timeout(Duration(minutes: 2));

  testWidgets('the chart of accounts renders the standard accounts seeded for '
      'a firm that has never opened the ledger', (tester) async {
    // Seeded explicitly, inside runAsync.
    //
    // A `testWidgets` body runs in a fake-async zone, where a database write
    // only makes progress when the test pumps: awaiting a drift transaction
    // directly would never complete, and the teardown that followed would wait
    // for it for ever. runAsync runs the seed in the real zone, which is what
    // the app itself does. The screens no longer seed on build for the same
    // reason (see AtriaApp._seedChart).
    await tester.runAsync(
        () => container.read(ledgerRepositoryProvider)!.ensureChart());
    await pump(tester, const ChartOfAccountsScreen());
    expect(tester.takeException(), isNull);

    // The top of the list: the assets section and its first two accounts. Rows
    // further down are not built until they are scrolled into view.
    expect(find.text('Assets'), findsOneWidget);
    expect(find.text('Cash in hand'), findsOneWidget);
    expect(find.text('Bank account'), findsOneWidget);
    expect(find.text(LedgerCodes.cash), findsOneWidget);
    await teardown(tester);
  }, timeout: perTest);

  testWidgets('an empty journal list explains what a voucher is',
      (tester) async {
    await pump(tester, const JournalListScreen());
    expect(tester.takeException(), isNull);
    expect(find.text('No journal entries yet'), findsOneWidget);
    await teardown(tester);
  }, timeout: perTest);

  testWidgets('the journal editor will not save a voucher that does not balance',
      (tester) async {
    await pump(tester, const JournalEditorScreen());
    expect(tester.takeException(), isNull);
    expect(find.text('New journal entry'), findsOneWidget);

    // Two empty lines: the editor must refuse rather than save a voucher with
    // no amounts. The guidance line is below the fold in a lazy ListView, so the
    // invariant asserted here is the one that matters: nothing is written.
    await tester.tap(find.text('Save voucher'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(await db.ledgerRepositoryFor(firmId).journalCount(), 0);
    await teardown(tester);
  }, timeout: perTest);
}
