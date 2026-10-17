import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/sources/business_status/bank_statement.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// **The Bank Statement, through the real write path.**
///
/// `report_bank_statement_test.dart` asserts the report's arithmetic against a
/// fixture that writes `bank_accounts.currentBalance` straight into the table.
/// That is the right way to test the *report*, but it also meant nothing ever
/// checked the **model** around it — and the model was hollow:
///
///  * `currentBalance` was documented as a cache "written in one transaction"
///    with the payment ledger, and written **nowhere** — so it sat at 0 for
///    ever, and every statement opened at `-<this period>` and never left
///    ₹0.00;
///  * `payments.bankAccountId` was never written by anything either, so the
///    report's `bankAccountId` predicate matched no payment at all;
///  * `bank_accounts` had no UI, so no row could be created to begin with.
///
/// These tests go through `PaymentRepository.create` / `update` /
/// `softDelete` / `restore` and then read the report, which is the only way to
/// prove the chain is actually closed.
void main() {
  late AppDatabase db;
  late String firmId;

  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firmId = (await db.firmRepository.create(name: 'Apex Traders')).id;
  });

  tearDown(() => db.close());

  Future<String> account({
    required String name,
    String type = 'bank',
    double opening = 0,
  }) async {
    final id = 'bac-${name.toLowerCase().replaceAll(' ', '-')}';
    await db
        .into(db.bankAccounts)
        .insert(
          BankAccountsCompanion.insert(
            id: id,
            firmId: firmId,
            name: name,
            type: Value(type),
            currentBalance: Value(opening),
            openingBalance: Value(opening),
          ),
        );
    return id;
  }

  Future<String> receipt({
    required double amount,
    required DateTime date,
    String? bankAccount,
    String? chequeStatus,
  }) async {
    final payments = db.paymentRepositoryFor(firmId);
    return (await payments.create(
      type: 'payment_in',
      number: 'RCPT-${date.day}',
      amount: amount,
      date: date,
      bankAccount: bankAccount,
      mode: chequeStatus == null ? 'bank' : 'cheque',
    )).id;
  }

  Future<List<ReportRow>> rowsFor({String? accountId}) =>
      bankStatement.source.build(
        db,
        firmId,
        window,
        accountId == null ? const {} : {kBankFilterId: accountId},
      );

  Decimal value(ReportRow row, String key) =>
      row.number(bankStatement.spec.columns.firstWhere((c) => c.key == key));

  Future<double> cachedBalance(String id) async => (await (db.select(
    db.bankAccounts,
  )..where((a) => a.id.equals(id))).getSingle()).currentBalance;

  group('the cache the report walks back from', () {
    test('a receipt updates the account balance', () async {
      final id = await account(name: 'HDFC main');
      await receipt(
        amount: 50000,
        date: DateTime(2026, 5, 2),
        bankAccount: 'HDFC main',
      );
      expect(
        await cachedBalance(id),
        50000,
        reason: 'currentBalance is what the whole report is derived from',
      );
    });

    test('a payment out reduces it', () async {
      final id = await account(name: 'HDFC main', opening: 10000);
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_out',
            number: 'PAY-1',
            amount: 2500,
            date: DateTime(2026, 5, 2),
            bankAccount: 'HDFC main',
          );
      expect(await cachedBalance(id), 7500);
    });

    test('binning a receipt takes the money back out', () async {
      final id = await account(name: 'HDFC main');
      final paymentId = await receipt(
        amount: 5000,
        date: DateTime(2026, 5, 2),
        bankAccount: 'HDFC main',
      );
      expect(await cachedBalance(id), 5000);

      final payments = db.paymentRepositoryFor(firmId);
      await payments.softDelete(paymentId);
      expect(await cachedBalance(id), 0);

      await payments.restore(paymentId);
      expect(await cachedBalance(id), 5000);
    });
  });

  group('linking a payment to an account', () {
    test('the free-text name resolves to the row', () async {
      final id = await account(name: 'HDFC main');
      final paymentId = await receipt(
        amount: 7000,
        date: DateTime(2026, 5, 4),
        bankAccount: 'HDFC main',
      );
      final stored = (await db
          .paymentRepositoryFor(firmId)
          .getById(paymentId))!;
      expect(
        stored.bankAccountId,
        id,
        reason: 'the report keys on bankAccountId, not the free-text name',
      );
    });

    test('the match ignores case and surrounding space', () async {
      final id = await account(name: 'HDFC Main');
      final paymentId = await receipt(
        amount: 7000,
        date: DateTime(2026, 5, 4),
        bankAccount: '  hdfc main  ',
      );
      expect(
        (await db.paymentRepositoryFor(firmId).getById(paymentId))!
            .bankAccountId,
        id,
      );
    });

    test(
      'an unknown name links nothing rather than inventing an account',
      () async {
        final paymentId = await receipt(
          amount: 7000,
          date: DateTime(2026, 5, 4),
          bankAccount: 'Some cash under the mat',
        );
        expect(
          (await db.paymentRepositoryFor(firmId).getById(paymentId))!
              .bankAccountId,
          isNull,
        );
      },
    );
  });

  group('end to end', () {
    test('a statement reconciles to the account balance', () async {
      final id = await account(name: 'HDFC main', opening: 10000);

      // 10,000 brought forward, +5,000 on 2 May, −2,500 on 11 May.
      await receipt(
        amount: 5000,
        date: DateTime(2026, 5, 2),
        bankAccount: 'HDFC main',
      );
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_out',
            number: 'PAY-2',
            amount: 2500,
            date: DateTime(2026, 5, 11),
            bankAccount: 'HDFC main',
          );

      final rows = await rowsFor(accountId: id);
      expect(rows, hasLength(2));

      // The opening is the balance *before* the window: 10,000.
      expect(value(rows[0], 'balance'), Decimal.fromInt(15000));
      expect(value(rows[1], 'balance'), Decimal.fromInt(12500));

      // …and the closing figure the report prints is the account's own cache.
      expect(await cachedBalance(id), 12500);
    });

    test('a bounced cheque is not money that arrived', () async {
      final id = await account(name: 'HDFC main');
      final paymentId = await receipt(
        amount: 50000,
        chequeStatus: 'pending',
        date: DateTime(2026, 5, 2),
        bankAccount: 'HDFC main',
      );
      await db
          .paymentRepositoryFor(firmId)
          .markChequeBounced(paymentId, reason: 'returned unpaid');

      // The statement drops the row, so the cached balance and the printed
      // balance cannot disagree about it.
      final rows = await rowsFor(accountId: id);
      expect(
        rows.any((r) => value(r, 'receipt') == Decimal.fromInt(50000)),
        isFalse,
      );
    });

    test('a loan is not counted against every account', () async {
      // `loan_transactions` has no `bankAccountId`, so the loan block used to
      // append the same disbursement to **each** account in the loop — and to
      // corrupt each one's opening, which is derived by subtracting movements.
      await account(name: 'HDFC main');
      await account(name: 'ICICI savings');
      final loanId = 'loan-1';
      await db
          .into(db.loans)
          .insert(
            LoansCompanion.insert(
              id: loanId,
              firmId: firmId,
              partyName: const Value('Ramesh'),
              direction: const Value('borrowed'),
              principalAmount: 200000.0,
              interestRate: const Value(10.0),
              startDate: DateTime(2026, 4, 1),
            ),
          );
      await db
          .into(db.loanTransactions)
          .insert(
            LoanTransactionsCompanion.insert(
              id: 'ltx-1',
              firmId: firmId,
              loanId: loanId,
              date: DateTime(2026, 4, 15),
              kind: 'disbursement',
              principalAmount: const Value(200000.0),
              amount: 200000.0,
            ),
          );

      final rows = await rowsFor();
      final loanRows = rows
          .where((r) => '${r.cells['particulars']}'.contains('Loan'))
          .toList();
      expect(
        loanRows,
        isEmpty,
        reason:
            'the Loan Statement owns loans; a bank statement cannot '
            'attribute one to an account that has no link to it',
      );
    });
  });
}
