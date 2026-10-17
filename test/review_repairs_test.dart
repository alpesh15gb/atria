import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atria/core/api/sync_client.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/bank_account_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/reports/sources/business_status/bank_statement.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/sync/pull_applier.dart';

void main() {
  late AppDatabase db;
  late String firm;
  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firm = (await db.firmRepository.create(name: 'Review repairs')).id;
  });
  tearDown(() => db.close());

  Map<String, Object?> wire(Map<String, dynamic> json) => json.map(
    (key, value) => MapEntry(
      key.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}'),
      value,
    ),
  );

  Future<void> account(String id, {double opening = 0}) =>
      BankAccountRepository(db, firm).save(
        BankAccountsCompanion(
          id: Value(id),
          firmId: Value(firm),
          name: Value(id),
          currentBalance: Value(opening),
        ),
      );
  Future<double> balance(String id) async =>
      (await db.select(db.bankAccounts).get())
          .singleWhere((a) => a.id == id)
          .currentBalance;

  test('P&L stock uses weighted average across purchases and sales', () async {
    final item = await db.itemRepositoryFor(firm).create(name: 'Widget');
    for (final (id, date, quantity, cost, kind) in [
      ('a', DateTime(2026, 4, 1), 1.0, 100.0, 'purchase'),
      ('b', DateTime(2026, 4, 2), 1.0, 200.0, 'purchase'),
      ('c', DateTime(2026, 4, 3), -1.0, 150.0, 'sale'),
    ]) {
      await db
          .into(db.stockMovements)
          .insert(
            StockMovementsCompanion.insert(
              id: id,
              firmId: firm,
              itemId: item.id,
              date: date,
              kind: kind,
              quantity: quantity,
              balanceAfter: const Value(0),
              source: 'test',
              unitCost: Value(cost),
            ),
          );
    }
    expect(
      await db
          .reportRepositoryFor(firm)
          .stockAtCost(asOf: DateTime(2026, 4, 2)),
      300,
    );
    expect(
      await db
          .reportRepositoryFor(firm)
          .stockAtCost(asOf: DateTime(2026, 4, 3)),
      150,
    );
    expect((await db.reportRepositoryFor(firm).dashboard()).stockValue.toString(), '150');
  });

  test(
    'bank selection moves the payment, and delete/restore are idempotent',
    () async {
      await account('A', opening: 100);
      await account('B', opening: 200);
      final repo = db.paymentRepositoryFor(firm);
      final receipt = await repo.create(
        type: 'payment_in',
        number: '1',
        amount: 50,
        date: DateTime(2026, 4, 1),
        bankAccount: 'A',
      );
      await repo.update(
        receipt.copyWith(
          bankAccount: const Value('B'),
          bankAccountId: const Value(null),
        ),
      );
      expect(await balance('A'), 100);
      expect(await balance('B'), 250);
      await repo.softDelete(receipt.id);
      await repo.softDelete(receipt.id);
      expect(await balance('B'), 200);
      await repo.restore(receipt.id);
      await repo.restore(receipt.id);
      expect(await balance('B'), 250);
    },
  );

  test(
    'pending, bounced and redeposited cheques affect bank only at clearance',
    () async {
      await account('A', opening: 100);
      final repo = db.paymentRepositoryFor(firm);
      final cheque = await repo.create(
        type: 'payment_in',
        number: 'C1',
        amount: 50,
        date: DateTime(2026, 4, 1),
        bankAccount: 'A',
        mode: 'cheque',
      );
      expect(await balance('A'), 100);
      await repo.markChequeBounced(cheque.id, reason: 'unpaid');
      expect(await balance('A'), 100);
      await repo.markChequeDeposited(cheque.id);
      expect(await balance('A'), 100);
      await repo.markChequeCleared(cheque.id, date: DateTime(2026, 5, 2));
      expect(await balance('A'), 150);
      final rows = await bankStatementRows(
        db,
        firm,
        ReportWindow(
          preset: ReportWindowPreset.custom,
          from: DateTime(2026, 4, 1),
          to: DateTime(2026, 4, 30),
        ),
        {},
      );
      expect(rows.single.cells['balance'].toString(), '100');
    },
  );

  test('historical statement excludes later and deleted movements', () async {
    await account('A', opening: 100);
    final repo = db.paymentRepositoryFor(firm);
    await repo.create(
      type: 'payment_in',
      number: '1',
      amount: 50,
      date: DateTime(2026, 4, 2),
      bankAccount: 'A',
    );
    await repo.create(
      type: 'payment_in',
      number: '2',
      amount: 70,
      date: DateTime(2026, 6, 2),
      bankAccount: 'A',
    );
    final deleted = await repo.create(
      type: 'payment_in',
      number: '3',
      amount: 90,
      date: DateTime(2026, 4, 3),
      bankAccount: 'A',
    );
    await repo.softDelete(deleted.id);
    final rows = await bankStatementRows(
      db,
      firm,
      ReportWindow(
        preset: ReportWindowPreset.custom,
        from: DateTime(2026, 4, 1),
        to: DateTime(2026, 4, 30),
      ),
      {},
    );
    expect(rows, hasLength(1));
    expect(rows.single.cells['balance'].toString(), '150');
  });

  test(
    'bank masters sync and pulled payments rebuild derived balances',
    () async {
      await account('A', opening: 100);
      expect(
        (await db.select(db.syncQueue).get()).any(
          (q) => q.entity == 'bank_accounts',
        ),
        isTrue,
      );
      final source = (await db.select(db.bankAccounts).get()).single;
      final payment = await db
          .paymentRepositoryFor(firm)
          .create(
            type: 'payment_in',
            number: '1',
            amount: 50,
            date: DateTime(2026, 4, 2),
            bankAccount: 'A',
          );
      final other = AppDatabase.test(NativeDatabase.memory());
      addTearDown(other.close);
      await other
          .into(other.firms)
          .insert((await db.firmRepository.getById(firm))!.toCompanion(true));
      final page = PullPage(
        changes: [
          JournaledChange(
            seq: 1,
            changeId: 'bank',
            entity: 'bank_accounts',
            entityId: source.id,
            operation: 'insert',
            payload: wire(source.toJson()),
            createdAt: DateTime.now(),
          ),
          JournaledChange(
            seq: 2,
            changeId: 'pay',
            entity: 'payments',
            entityId: payment.id,
            operation: 'insert',
            payload: wire(payment.toJson()),
            createdAt: DateTime.now(),
          ),
        ],
        hasMore: false,
      );
      final result = await PullApplier(other)
          .applyPage(firmId: firm, page: page);
      expect(result.skipped, 0);
      expect(
        (await other.select(other.bankAccounts).get()).single.currentBalance,
        150,
      );
    },
  );

  test(
    'v12 migration recovers opening and removes uncleared cheque money',
    () async {
      final directory = Directory.systemTemp.createTempSync('atria_bank_v13_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/books.sqlite');
      final old = AppDatabase.test(NativeDatabase(file));
      final oldFirm = (await old.firmRepository.create(name: 'Upgrade')).id;
      await old
          .into(old.bankAccounts)
          .insert(
            BankAccountsCompanion.insert(
              id: 'bank',
              firmId: oldFirm,
              name: 'Bank',
              currentBalance: const Value(150),
            ),
          );
      await old
          .into(old.payments)
          .insert(
            PaymentsCompanion.insert(
              id: 'pay',
              firmId: oldFirm,
              type: 'payment_in',
              number: 'C',
              amount: 50,
              date: DateTime(2026, 4, 1),
              mode: const Value('cheque'),
              chequeStatus: const Value('pending'),
              bankAccountId: const Value('bank'),
            ),
          );
      await old.customStatement(
        'ALTER TABLE bank_accounts DROP COLUMN opening_balance',
      );
      await old.customStatement('PRAGMA user_version = 12');
      await old.close();
      final upgraded = AppDatabase.test(NativeDatabase(file));
      addTearDown(upgraded.close);
      final bank = (await upgraded.select(upgraded.bankAccounts).get()).single;
      expect(bank.openingBalance, 100);
      expect(bank.currentBalance, 100);
    },
  );
}
