import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Archiving an account retires it from the picker, it does not erase its
/// opening balance. The chart's own delete dialog sends users with history
/// here for exactly that reason, and `setAccountActive` promises the account
/// "stays in the chart for the entries that reference it". When the books were
/// built from active accounts only, an archived account's opening balance
/// vanished with no contra entry — the trial balance went out by that amount
/// and the balance sheet stopped foots, while still printing "in balance"
/// banners everywhere else.

void main() {
  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(name: 'Apex Traders');
    firmId = firm.id;
  });

  tearDown(() => db.close());

  test('an archived account keeps its opening balance in the books', () async {
    final ledger = db.ledgerRepositoryFor(firmId);
    await ledger.ensureChart();
    final account = await ledger.createAccount(
      name: 'Furniture and fixtures',
      type: 'asset',
      openingBalance: 50000,
      openingType: 'dr',
    );
    // A real opening is a balanced pair: the asset against capital. An
    // unbalanced one puts the trial balance out before and after, which would
    // make the check below meaningless.
    final capital = await ledger.byCode(LedgerCodes.capital);
    await ledger.updateAccount(capital!.copyWith(
      openingBalance: capital.openingBalance + 50000,
      openingType: 'cr',
    ));

    Future<double> closingFor(String code) async {
      final tb = await ledger.trialBalance(asOf: DateTime.now());
      final row = tb.rows.singleWhere((r) => r.account.code == code);
      return row.closingDebit - row.closingCredit;
    }

    expect(await closingFor(account.code), 50000);
    final before = await ledger.trialBalance(asOf: DateTime.now());
    expect(before.isBalanced, isTrue, reason: 'the test opens balanced books');

    await ledger.setAccountActive(account.id, false);

    // The opening balance is still on the books, so the account keeps its
    // closing balance and the trial balance still foots.
    expect(await closingFor(account.code), 50000);
    final tb = await ledger.trialBalance(asOf: DateTime.now());
    expect(tb.isBalanced, isTrue,
        reason: 'archiving must not erase an opening balance');
  });

  test('an archived account keeps its movements', () async {
    final ledger = db.ledgerRepositoryFor(firmId);
    final account = await ledger.createAccount(
      name: 'Freight income',
      type: 'income',
      openingBalance: 0,
    );
    // The other side of a balanced voucher.
    final bank = await ledger.byCode('1010') ??
        await ledger.createAccount(name: 'Bank', type: 'asset');

    await ledger.createJournal(
      date: DateTime.now(),
      narration: 'Freight billed',
      lines: [
        JournalLineDraft(accountId: bank.id, debit: 5000),
        JournalLineDraft(accountId: account.id, credit: 5000),
      ],
    );

    await ledger.setAccountActive(account.id, false);

    // The movement did not get re-posted to Suspense: it still lands in the
    // account it was written to.
    final detail = await ledger.accountLedger(account.id,
        from: DateTime(2000), asOf: DateTime.now());
    expect(detail.rows, isNotEmpty);
    expect(detail.totalCredit, 5000,
        reason: 'a retired account keeps its own history');
  });
}
