import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/schema_rollback.dart';

/// The v11 → v12 upgrade: bank accounts, loans, TDS metadata, expense items.
///
/// Built by rolling a real v12 database *back* — drop what v12 added, set
/// `user_version` to 11, reopen. That gives a file whose rows really do predate
/// the columns, which is the only honest way to test that the migration keeps
/// them.
///
/// Each addition here exists because a report cannot be built without it, and
/// each has a way of being wrong that reading the schema would never reveal —
/// which is why the assertions are about *values* (a PAN that was never
/// captured stays null, the free-text bank account is not discarded, the
/// existing TDS figures do not move) rather than about columns merely existing.
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('atria_v12_migration');
    file = File('${dir.path}/books.db');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// The index names drift only applies when a table is created fresh, so an
  /// upgraded database has to be asked for them explicitly. A missing index is
  /// otherwise invisible until the one device with years of history starts
  /// scanning a whole table on every keystroke.
  Future<void> expectIndex(AppDatabase db, String table, String name) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND tbl_name = '$table'",
        )
        .get();
    expect(
      rows.map((r) => r.read<String>('name')),
      contains(name),
      reason: '$table has no $name index after the upgrade',
    );
  }

  test('existing rows survive and pick up the new defaults', () async {
    // Only tables that existed *before* v12 can be seeded here: the rollback
    // drops the new tables, and a dropped table takes its rows with it. So the
    // "rows survive" claim is tested on the additive columns, which is the only
    // place it can be tested honestly. The new tables get the test below.
    //
    // 1. Build a current database with a firm and a row in every pre-v12 table
    //    that v12 adds a column to.
    final first = AppDatabase.test(NativeDatabase(file));
    final firm = await first.firmRepository.create(name: 'Alpha Traders');
    final firmId = firm.id;

    await first
        .into(first.payments)
        .insert(
          PaymentsCompanion.insert(
            id: 'pmt-1',
            firmId: firmId,
            type: 'payment_out',
            number: 'PMT-001',
            amount: 27500,
            date: DateTime(2026, 5, 5),
            bankAccount: const Value('HDFC Main'),
          ),
        );
    await first
        .into(first.expenses)
        .insert(
          ExpensesCompanion.insert(
            id: 'exp-1',
            firmId: firmId,
            number: 'EXP-001',
            category: 'Travel',
            amount: 1200,
            date: DateTime(2026, 5, 6),
          ),
        );
    await first
        .into(first.purchaseBills)
        .insert(
          PurchaseBillsCompanion.insert(
            id: 'bill-1',
            firmId: firmId,
            number: 'PUR-001',
            billDate: DateTime(2026, 5, 7),
            tds: const Value(500),
            tdsRate: const Value(0.1),
          ),
        );

    // 2. Roll it back to what a v11 file looked like.
    await SchemaRollback.bankingV12(first);
    await SchemaRollback.setVersion(first, 11);
    await first.close();

    // 3. Reopen: this runs the v11 → v12 upgrade for real.
    final upgraded = AppDatabase.test(NativeDatabase(file));
    addTearDown(upgraded.close);
    expect(upgraded.schemaVersion, 12);

    final firmRow = await (upgraded.select(
      upgraded.firms,
    )..where((f) => f.id.equals(firmId))).getSingle();
    expect(firmRow.name, 'Alpha Traders', reason: 'the row must survive');

    final payment = await upgraded.select(upgraded.payments).getSingle();
    expect(payment.amount, 27500);
    expect(
      payment.bankAccountId,
      isNull,
      reason: 'an upgrade must not invent a link the old row never had',
    );
    expect(
      payment.bankAccount,
      'HDFC Main',
      reason:
          'the free-text account is not discarded — it is on documents '
          'already printed, and it is what an older build reads back',
    );

    final expense = await upgraded.select(upgraded.expenses).getSingle();
    expect(expense.category, 'Travel');
    expect(expense.amount, 1200);
    expect(expense.itemId, isNull);

    final bill = await upgraded.select(upgraded.purchaseBills).getSingle();
    expect(bill.tds, 500, reason: 'the deduction itself must not move');
    expect(bill.tdsRate, 0.1);
    expect(
      bill.deducteePan,
      isNull,
      reason:
          'a PAN that was never captured must never be invented — a 26Q '
          'filed against a guessed PAN is worse than one not filed',
    );
    expect(bill.tdsSection, isNull);
    expect(bill.tdsSectionRate, 0);
  });

  test('the new tables exist, are empty, and are usable', () async {
    // A firm whose books predate v12 must be able to name a bank account and a
    // loan without the query failing on a table that is not there. Asserting
    // only "the table exists" would pass on a table with the wrong shape, so
    // this writes a full row through it and reads the defaults back.
    final first = AppDatabase.test(NativeDatabase(file));
    final firm = await first.firmRepository.create(name: 'Alpha Traders');
    await SchemaRollback.bankingV12(first);
    await SchemaRollback.setVersion(first, 11);
    await first.close();

    final upgraded = AppDatabase.test(NativeDatabase(file));
    addTearDown(upgraded.close);
    expect(upgraded.schemaVersion, 12);

    expect(await upgraded.select(upgraded.bankAccounts).get(), isEmpty);
    expect(await upgraded.select(upgraded.loans).get(), isEmpty);
    expect(await upgraded.select(upgraded.loanTransactions).get(), isEmpty);
    expect(await upgraded.select(upgraded.gstr9Adjustments).get(), isEmpty);

    final account = await upgraded
        .into(upgraded.bankAccounts)
        .insertReturning(
          BankAccountsCompanion.insert(
            id: 'bank-new',
            firmId: firm.id,
            name: 'HDFC Main',
            accountNumber: const Value('50100234567890'),
          ),
        );
    expect(account.type, 'bank', reason: 'the default has to be the sane one');
    expect(account.currentBalance, 0);
    expect(account.isArchived, isFalse);

    final loan = await upgraded
        .into(upgraded.loans)
        .insertReturning(
          LoansCompanion.insert(
            id: 'loan-1',
            firmId: firm.id,
            direction: const Value('borrowed'),
            partyName: const Value('Sriram Finance'),
            principalAmount: 200000,
            startDate: DateTime(2026, 4, 1),
          ),
        );
    expect(loan.direction, 'borrowed');
    expect(loan.outstandingAmount, 0);
    expect(loan.interestType, 'simple');
    expect(loan.interestRate, 0);

    final ltxn = await upgraded
        .into(upgraded.loanTransactions)
        .insertReturning(
          LoanTransactionsCompanion.insert(
            id: 'ltxn-1',
            firmId: firm.id,
            loanId: loan.id,
            kind: 'repayment',
            principalAmount: const Value(25000),
            amount: 27500,
            date: DateTime(2026, 5, 5),
          ),
        );
    expect(
      ltxn.interestAmount,
      0,
      reason:
          'interest is snapshotted per transaction, not re-derived from '
          "the loan's rate — a rate renegotiated mid-term must not rewrite "
          'what a February repayment was worth',
    );
    expect(ltxn.mode, 'cash');

    final adj = await upgraded
        .into(upgraded.gstr9Adjustments)
        .insertReturning(
          Gstr9AdjustmentsCompanion.insert(
            id: 'adj-1',
            firmId: firm.id,
            schedule: '4.1A',
            description: 'ITC on capital goods',
            amount: 8400,
            date: DateTime(2026, 6, 30),
            financialYearStart: DateTime(2026, 4, 1),
          ),
        );
    expect(adj.direction, 'addition');
    expect(
      adj.financialYearStart,
      DateTime(2026, 4, 1),
      reason:
          'GSTR-9 is 1 Apr – 31 Mar and a return on the wrong window is '
          'legally wrong even when it is arithmetically perfect',
    );

    await expectIndex(upgraded, 'bank_accounts', 'idx_bank_accounts_firm');
    await expectIndex(upgraded, 'loans', 'idx_loans_firm');
    await expectIndex(upgraded, 'loans', 'idx_loans_party');
    await expectIndex(upgraded, 'loan_transactions', 'idx_loan_txn_loan');
    await expectIndex(upgraded, 'gstr9_adjustments', 'idx_gstr9_adj_firm');
  });
}
