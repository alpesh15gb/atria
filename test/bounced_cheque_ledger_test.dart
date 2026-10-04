import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bounced cheque is money that never arrived. The payment repository
/// already stops it settling its invoice (`_recomputeLinkedDoc` skips rows
/// with `chequeStatus == 'bounced'`), so the ledger has to agree — otherwise
/// the books show a phantom asset in Cheques in hand against a receivable the
/// party report still says is owed, and the trial balance foots over a sheet
/// that is wrong.

void main() {
  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(name: 'Apex Traders');
    firmId = firm.id;
  });

  tearDown(() => db.close());

  Future<double> chequesInHand() async {
    final ledger = db.ledgerRepositoryFor(firmId);
    final tb = await ledger.trialBalance(asOf: DateTime.now());
    final row = tb.rows
        .singleWhere((r) => r.account.code == LedgerCodes.chequesInHand,
            orElse: () => throw StateError('no cheques-in-hand row'));
    return row.debit;
  }

  test('a cheque in hand posts to the ledger', () async {
    await db.paymentRepositoryFor(firmId).create(
          type: 'payment_in',
          number: 'R-001',
          partyName: 'Customer',
          amount: 10000,
          date: DateTime.now(),
          mode: 'cheque',
        );

    expect(await chequesInHand(), 10000);
  });

  test('a bounced cheque does not stay in the books as an asset', () async {
    final payments = db.paymentRepositoryFor(firmId);
    final cheque = await payments.create(
      type: 'payment_in',
      number: 'R-001',
      partyName: 'Customer',
      amount: 10000,
      date: DateTime.now(),
      mode: 'cheque',
    );
    expect(await chequesInHand(), 10000);

    await payments.markChequeBounced(cheque.id, reason: 'Insufficient funds');

    // The account has no movements left, and trialBalance skips all-zero rows,
    // so the phantom asset is gone rather than sitting at a misleading zero.
    expect(
      () => chequesInHand(),
      throwsStateError,
      reason: 'a returned cheque must not remain on the balance sheet',
    );

    // And the books still foot, which is what makes the omission easy to miss.
    final ledger = db.ledgerRepositoryFor(firmId);
    final tb = await ledger.trialBalance(asOf: DateTime.now());
    expect(tb.totalClosingDebit, 0);
    expect(tb.totalClosingCredit, 0);
  });

  test('a cleared cheque stays in the books', () async {
    final payments = db.paymentRepositoryFor(firmId);
    final cheque = await payments.create(
      type: 'payment_in',
      number: 'R-001',
      partyName: 'Customer',
      amount: 10000,
      date: DateTime.now(),
      mode: 'cheque',
    );

    // Only the bounce reverses a cheque. Clearing is the money actually
    // arriving, so it must remain — and it moves from Cheques in hand to Bank.
    await payments.markChequeCleared(cheque.id);
    final ledger = db.ledgerRepositoryFor(firmId);
    final tb = await ledger.trialBalance(asOf: DateTime.now());
    final bank = tb.rows.singleWhere(
      (r) => r.account.code == LedgerCodes.bank,
      orElse: () => throw StateError('no bank row'),
    );
    expect(bank.debit, 10000);
  });
}
