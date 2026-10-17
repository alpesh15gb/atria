import 'package:atria/core/api/sync_client.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/audit_repository.dart';
import 'package:atria/core/sync/pull_applier.dart';
import 'package:atria/core/utils/formatters.dart';
import 'package:atria/core/domain/member_role.dart';
import 'package:atria/core/database/repositories/bank_account_repository.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable, Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late String firmId;
  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firmId = (await db.firmRepository.create(
      name: 'Independent audit',
      stateCode: '29',
    )).id;
  });
  tearDown(() => db.close());

  test('REPAIRED: overdraft input preserves its sign', () {
    final result = IndianAmountInputFormatter(signed: true).formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(text: '-5000'),
    );
    expect(result.text, '-5,000');
  });

  test('REPAIRED: locked payment cannot move to unlocked date', () async {
    final repo = db.paymentRepositoryFor(firmId);
    final payment = await repo.create(
      type: 'payment_in',
      number: 'P1',
      amount: 100,
      date: DateTime(2026, 9, 1),
    );
    await PeriodLock(db.settingsRepository)
        .lockThrough(DateTime(2026, 9, 30), firmId: firmId);
    await expectLater(
      repo.update(payment.copyWith(date: DateTime(2026, 10, 1), amount: 200)),
      throwsA(isA<PeriodLockedException>()),
    );
    expect((await repo.getById(payment.id))!.amount, 100);
  });

  test('REPAIRED: locked expense cannot move to unlocked date', () async {
    final repo = db.expenseRepositoryFor(firmId);
    final expense = await repo.create(
      type: 'expense',
      number: 'E1',
      category: 'rent',
      amount: 100,
      date: DateTime(2026, 9, 1),
    );
    await PeriodLock(db.settingsRepository)
        .lockThrough(DateTime(2026, 9, 30), firmId: firmId);
    await expectLater(
      repo.update(expense.copyWith(date: DateTime(2026, 10, 1), amount: 200)),
      throwsA(isA<PeriodLockedException>()),
    );
    expect((await repo.getById(expense.id))!.amount, 100);
  });

  test('REPAIRED: stock changes do not enqueue item cache update or rebuild on pull', () async {
    final repo = db.itemRepositoryFor(firmId);
    final item = await repo.create(
      name: 'Stock probe',
      openingStock: 10,
      purchasePrice: 50,
    );
    await db.delete(db.syncQueue).go();
    await repo.applyStockEffect(
      itemId: item.id,
      quantity: -2,
      kind: 'sale',
      source: 'manual',
    );
    final queue = await db.select(db.syncQueue).get();
    expect(queue.map((q) => q.entity), ['stock_movements']);
    expect((await repo.getById(item.id))!.currentStock, 8);
    final movement =
        (await db
                .customSelect(
                  'SELECT * FROM stock_movements WHERE kind = \'sale\'',
                )
                .get())
            .single
            .data;
    // Receiver has the last synchronized item count (10), then receives the
    // next movement, exactly the entity that the real writer enqueued.
    await db.customUpdate('DELETE FROM stock_movements WHERE kind = \'sale\'');
    await db.customUpdate(
      'UPDATE items SET current_stock = 10 WHERE id = ?',
      variables: [Variable.withString(item.id)],
    );
    await PullApplier(db).applyPage(
      firmId: firmId,
      page: PullPage(
        hasMore: false,
        changes: [
          JournaledChange(
            seq: 1,
            changeId: 'remote-stock',
            entity: 'stock_movements',
            entityId: movement['id'] as String,
            operation: 'insert',
            payload: movement,
          ),
        ],
      ),
    );
    expect((await repo.getById(item.id))!.currentStock, 8);
    final sum =
        (await db
                .customSelect(
                  'SELECT SUM(quantity) AS qty FROM stock_movements',
                )
                .get())
            .single
            .data['qty'];
    expect(sum, 8);
  });

  test(
    'REPAIRED: payload-bearing soft delete stays in the receiver recycle bin',
    () async {
      final repo = db.paymentRepositoryFor(firmId);
      final p = await repo.create(
        type: 'payment_in',
        number: 'P2',
        amount: 100,
        date: DateTime(2026, 10, 1),
      );
      await repo.softDelete(p.id);
      final q = (await db.select(db.syncQueue).get()).last;
      expect(q.operation, 'delete');
      final payload =
          (await db.customSelect('SELECT * FROM payments').get()).single.data;
      await PullApplier(db).applyPage(
        firmId: firmId,
        page: PullPage(
          hasMore: false,
          changes: [
            JournaledChange(
              seq: 1,
              changeId: 'remote-soft-delete',
              entity: q.entity,
              entityId: p.id,
              operation: q.operation,
              payload: payload,
            ),
          ],
        ),
      );
      expect((await repo.getById(p.id))!.isDeleted, isTrue);
    },
  );

  test(
    'REPAIRED: payment and expense purge enqueue purge tombstones',
    () async {
      final payments = db.paymentRepositoryFor(firmId);
      final p = await payments.create(
        type: 'payment_in',
        number: 'P3',
        amount: 100,
        date: DateTime(2026, 10, 1),
      );
      await payments.softDelete(p.id);
      final expenses = db.expenseRepositoryFor(firmId);
      final e = await expenses.create(
        type: 'expense',
        number: 'E2',
        category: 'rent',
        amount: 100,
        date: DateTime(2026, 10, 1),
      );
      await expenses.softDelete(e.id);
      await db.delete(db.syncQueue).go();
      await payments.deleteForever(p.id);
      await expenses.deleteForever(e.id);
      expect(
        (await db.select(db.syncQueue).get()).map((e) => e.entity).toSet(),
        {'payments', 'expenses'},
      );
    },
  );

  test('REPAIRED: read-only accountant cannot manually adjust stock', () async {
    final repo = db.itemRepositoryFor(firmId);
    final item = await repo.create(name: 'Permission probe', openingStock: 10);
    db.session = const MemberSession(
      enabled: true,
      memberId: 'audit-accountant',
      role: MemberRole.accountant,
    );
    await expectLater(
      repo.applyStockEffect(
        itemId: item.id,
        quantity: 5,
        kind: 'adjustment',
        source: 'adjustment',
      ),
      throwsA(isA<PermissionDeniedException>()),
    );
    expect((await repo.getById(item.id))!.currentStock, 10);
  });

  test('REPAIRED: backup containing loan transactions restores with production foreign keys', () async {
    await db.customStatement('PRAGMA foreign_keys=ON');
    await db
        .into(db.loans)
        .insert(
          LoansCompanion.insert(
            id: 'audit-loan',
            firmId: firmId,
            principalAmount: 1000,
            startDate: DateTime(2026, 10, 1),
          ),
        );
    await db
        .into(db.loanTransactions)
        .insert(
          LoanTransactionsCompanion.insert(
            id: 'audit-loan-tx',
            firmId: firmId,
            loanId: 'audit-loan',
            kind: 'disbursement',
            amount: 1000,
            date: DateTime(2026, 10, 1),
          ),
        );
    final backup = await db.backupRepository.export();
    Object? failure;
    try {
      await db.backupRepository.importFromJson(backup);
    } catch (e) {
      failure = e;
    }
    expect(failure, isNull);
    expect((await db.select(db.loanTransactions).get()).length, 1);
    // The transaction must roll back rather than erase the source books.
    expect((await db.select(db.loans).get()).length, 1);
  });

  test('REPAIRED: expense list cap includes all rows', () async {
    final repo = db.expenseRepositoryFor(firmId);
    await db.batch(
      (b) => b.insertAll(db.expenses, [
        for (var i = 0; i < 1001; i++)
          ExpensesCompanion.insert(
            id: 'cap-$i',
            firmId: firmId,
            number: 'E-$i',
            category: 'rent',
            amount: 10,
            date: DateTime(2026, 10, 1),
          ),
      ]),
    );
    final visible = await repo.watchList(limit: 0).first;
    expect(visible.length, 1001);
    expect(visible.fold<double>(0, (s, e) => s + e.amount), 10010);
    expect(await repo.totalForType('expense'), 10010);
  });

  test(
    'REPAIRED: dashboard includes opening receivables and unallocated receipts',
    () async {
      final party = await db
          .partyRepositoryFor(firmId)
          .create(name: 'Opening debtor', openingBalance: 1000);
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_in',
            number: 'ADV1',
            partyId: party.id,
            amount: 200,
            date: DateTime.now(),
          );
      final actual = await db
          .partyRepositoryFor(firmId)
          .outstandingFor(party.id);
      final summary = await db.reportRepositoryFor(firmId).dashboard();
      expect(actual, 800);
      expect(summary.receivable, Decimal.fromInt(800));
    },
  );

  test('REPAIRED: dashboard cash includes paid cash expenses', () async {
    await db
        .paymentRepositoryFor(firmId)
        .create(
          type: 'payment_in',
          number: 'CASH1',
          amount: 1000,
          date: DateTime.now(),
        );
    await db
        .expenseRepositoryFor(firmId)
        .create(
          type: 'expense',
          number: 'EXP1',
          category: 'rent',
          amount: 200,
          date: DateTime.now(),
        );
    final summary = await db.reportRepositoryFor(firmId).dashboard();
    final tb = await db
        .ledgerRepositoryFor(firmId)
        .trialBalance(asOf: DateTime.now());
    final cash = tb.rows
        .singleWhere((r) => r.account.code == LedgerCodes.cash)
        .closing;
    expect(summary.cashBalance!.toDouble(), 800);
    expect(cash, 800);
  });

  test(
    'REPAIRED: bank opening balance enters a balanced trial balance',
    () async {
      await BankAccountRepository(db, firmId).save(
        BankAccountsCompanion.insert(
          id: 'opening-bank',
          firmId: firmId,
          name: 'Audit Bank',
          openingBalance: const Value(1000),
          currentBalance: const Value(1000),
        ),
      );
      final account = (await db.select(db.bankAccounts).get()).single;
      final tb = await db
          .ledgerRepositoryFor(firmId)
          .trialBalance(asOf: DateTime.now());
      final bank = tb.rows
          .where((r) => r.account.code == LedgerCodes.bank)
          .fold<double>(0, (s, r) => s + r.closing);
      expect(account.currentBalance, 1000);
      expect(bank, 1000);
      expect(tb.isBalanced, isTrue);
    },
  );

  test('REPAIRED: editing linked receipt changes local invoice and synchronizes settlement', () async {
    final sales = db.salesRepositoryFor(firmId);
    final invoice = await sales.save(
      SalesDraft(
        id: 'receipt-invoice',
        number: 'INV-P',
        docType: 'invoice',
        invoiceDate: DateTime.now(),
        lines: [
          SalesLineDraft(
            id: 'receipt-line',
            name: 'Service',
            quantity: Decimal.one,
            unit: 'pcs',
            rate: Decimal.fromInt(100),
            gstRate: 0,
          ),
        ],
      ),
    );
    final payments = db.paymentRepositoryFor(firmId);
    final p = await payments.create(
      type: 'payment_in',
      number: 'REC-P',
      amount: 100,
      date: DateTime.now(),
      linkedInvoiceId: invoice.id,
      onLinked: (id, amount) =>
          sales.applyPayment(invoiceId: id, amount: amount),
    );
    await db.delete(db.syncQueue).go();
    await payments.update(p.copyWith(amount: 40));
    expect((await sales.getById(invoice.id))!.balanceDue, 60);
    final entries = await db.select(db.syncQueue).get();
    expect(entries.map((e) => e.entity), ['payments']);
    final payload =
        (await db.customSelect('SELECT * FROM payments').get()).single.data;
    // Model the receiving device's existing fully paid invoice and apply the
    // only changed entity the real edit queued.
    await db.customUpdate(
      'UPDATE sales_invoices SET paid_amount=100,balance_due=0,payment_status=\'paid\'',
    );
    await PullApplier(db).applyPage(
      firmId: firmId,
      page: PullPage(
        hasMore: false,
        changes: [
          JournaledChange(
            seq: 1,
            changeId: 'remote-receipt-edit',
            entity: 'payments',
            entityId: p.id,
            operation: 'update',
            payload: payload,
          ),
        ],
      ),
    );
    expect((await sales.getById(invoice.id))!.balanceDue, 60);
    expect((await payments.getById(p.id))!.amount, 40);
  });
  test('REPAIRED: saving an already-open item editor preserves intervening stock movements', () async {
    final repo = db.itemRepositoryFor(firmId);
    final editorSnapshot = await repo.create(
      name: 'Old name',
      openingStock: 10,
    );
    await repo.applyStockEffect(
      itemId: editorSnapshot.id,
      quantity: -2,
      kind: 'sale',
      source: 'manual',
    );
    await repo.update(editorSnapshot.copyWith(name: 'New name'));
    final item = (await repo.getById(editorSnapshot.id))!;
    expect(item.currentStock, 8);
    final sum =
        (await db
                .customSelect(
                  'SELECT SUM(quantity) AS qty FROM stock_movements',
                )
                .get())
            .single
            .data['qty'];
    expect(sum, 8);
  });
  test(
    'REPAIRED: synchronized recycle and restore preserves invoice lines',
    () async {
      await db.customStatement('PRAGMA foreign_keys=ON');
      final sales = db.salesRepositoryFor(firmId);
      final invoice = await sales.save(
        SalesDraft(
          id: 'restore-invoice',
          number: 'INV-R',
          docType: 'invoice',
          invoiceDate: DateTime.now(),
          lines: [
            SalesLineDraft(
              id: 'restore-line',
              name: 'Service',
              quantity: Decimal.one,
              unit: 'pcs',
              rate: Decimal.fromInt(100),
              gstRate: 0,
            ),
          ],
        ),
      );
      await sales.softDelete(invoice.id);
      final deleted =
          (await db.customSelect('SELECT * FROM sales_invoices').get())
              .single
              .data;
      await db.delete(db.syncQueue).go();
      await sales.restore(invoice.id);
      final restored =
          (await db.customSelect('SELECT * FROM sales_invoices').get())
              .single
              .data;
      expect(
        (await db.select(db.syncQueue).get()).any(
          (r) => r.entity == 'sales_invoice_items',
        ),
        false,
      );
      await PullApplier(db).applyPage(
        firmId: firmId,
        page: PullPage(
          hasMore: false,
          changes: [
            JournaledChange(
              seq: 1,
              changeId: 'remote-recycle',
              entity: 'sales_invoices',
              entityId: invoice.id,
              operation: 'delete',
              payload: deleted,
            ),
            JournaledChange(
              seq: 2,
              changeId: 'remote-restore',
              entity: 'sales_invoices',
              entityId: invoice.id,
              operation: 'update',
              payload: restored,
            ),
          ],
        ),
      );
      expect((await sales.getById(invoice.id))!.grandTotal, 100);
      expect(await sales.itemsFor(invoice.id), hasLength(1));
    },
  );
}
