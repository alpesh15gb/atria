import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/ledger/journal_editor_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A voucher written to an account that was later archived still has to open.

/// `setAccountActive` retires an account from the chart, it does not erase it
/// from history — the chart's own delete dialog sends users with a balance here
/// for exactly that reason. But the editor used to offer only *active*
/// accounts in its dropdowns, while still handing the line's archived account
/// id to the dropdown as its initial value. A dropdown asserts that its
/// initial value matches one of its items, so editing an old voucher asserted
/// in debug and rendered a blank, unusable field in release.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firmId = (await db.firmRepository.create(name: 'Apex Traders')).id;
  });

  tearDown(() => db.close());

  /// Tears the container down the way a screen holding a drift watch needs: the
  /// existence watch [ActiveFirmController.select] installs keeps stream
  /// teardown timers pending, and they only fire when the fake clock is
  /// pumped. See [stock_screen_regression_test] for the same workaround.
  Future<void> disposeWithMountedDrift(
    WidgetTester tester,
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
  }

  testWidgets(
    'an archived account stays selectable on its own voucher',
    timeout: timeout,
    (tester) async {
      final ledger = db.ledgerRepositoryFor(firmId);
      await ledger.ensureChart();
      final equipment = await ledger.createAccount(
        name: 'Office equipment',
        type: 'asset',
        openingBalance: 0,
      );
      // The other side of a balanced voucher, pulled from the seeded chart so the
      // books foot while this test is reading them.
      final bank =
          await ledger.byCode(LedgerCodes.bank) ??
          await ledger.createAccount(name: 'Bank', type: 'asset');

      final entry = await ledger.createJournal(
        date: DateTime.now(),
        narration: 'Desk bought for the office',
        lines: [
          JournalLineDraft(accountId: equipment.id, debit: 12000),
          JournalLineDraft(accountId: bank.id, credit: 12000),
        ],
      );

      // The account is retired from the chart after the voucher was written. Its
      // movements stay on the books, but nothing new may be posted to it.
      await ledger.setAccountActive(equipment.id, false);
      expect(
        (await ledger.allAccounts(includeInactive: true))
            .firstWhere((a) => a.id == equipment.id)
            .isActive,
        isFalse,
      );

      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      await container.read(activeFirmIdProvider.notifier).select(firmId);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: JournalEditorScreen(editId: entry.id)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The voucher loaded, and the archived account renders as a real,
      // labelled field rather than a blank one. A dropdown whose initial value
      // is absent from its items asserts here in debug, so this pump is itself
      // the regression check.
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Office equipment'), findsOneWidget);
      expect(
        find.textContaining('(archived)'),
        findsOneWidget,
        reason:
            'a retired account has to be marked, not silently mixed back '
            'into the chart',
      );

      // The editor still names the voucher it is editing, so the operator knows
      // which record they are changing.
      expect(find.textContaining('Journal'), findsOneWidget);

      await disposeWithMountedDrift(tester, container);
    },
  );
}
