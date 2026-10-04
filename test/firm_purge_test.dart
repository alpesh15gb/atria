import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
// Only `Value`, and deliberately not `show`-ing the whole of drift: it exports
// `isNull`/`isNotNull` too, which collide with the matcher library's.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Erasing a business has to be complete. A row left behind is worse than a
/// failed delete, because nothing will ever come back for it: the firm it
/// belonged to no longer exists, so no screen can show it, no report can
/// reconcile it, and no later sync can clean it up.
///
/// The test database deliberately does **not** enable `PRAGMA foreign_keys` —
/// the same as every other in-memory test here. That makes this a stronger
/// check, not a weaker one: `ON DELETE CASCADE` could hide a table that the
/// erasure forgot, whereas an explicit list cannot.
void main() {
  late AppDatabase db;

  const doomed = 'firm-doomed';
  const survivor = 'firm-survivor';
  const doomedInvoice = 'invoice-doomed';
  const doomedBill = 'bill-doomed';

  Future<int> countWhere(String table, String where) async {
    final row = await db
        .customSelect('SELECT count(*) AS n FROM $table WHERE $where')
        .getSingle();
    return row.read<int>('n');
  }

  /// Every table in the schema that has a `firm_id` column.
  ///
  /// Read out of SQLite rather than listed by hand so this test starts failing
  /// the moment somebody adds a table that belongs to a firm and does not teach
  /// [eraseFirmRows] about it — which is the only way that bug ever appears.
  Future<List<String>> tablesWithFirmId() async {
    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%'",
        )
        .get();
    final found = <String>[];
    for (final table in tables) {
      final name = table.read<String>('name');
      final columns = await db.customSelect('PRAGMA table_info($name)').get();
      if (columns.any((column) => column.read<String>('name') == 'firm_id')) {
        found.add(name);
      }
    }
    return found;
  }

  Future<void> seed(String firmId, String suffix) async {
    final now = DateTime(2026, 4, 1);
    await db
        .into(db.firms)
        .insert(FirmsCompanion.insert(id: firmId, name: 'Business $suffix'));
    await db
        .into(db.firmMembers)
        .insert(
          FirmMembersCompanion.insert(
            id: 'member-$suffix',
            firmId: firmId,
            name: 'Owner $suffix',
          ),
        );
    await db
        .into(db.parties)
        .insert(
          PartiesCompanion.insert(
            id: 'party-$suffix',
            firmId: firmId,
            name: 'Customer $suffix',
            type: 'customer',
          ),
        );
    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: 'category-$suffix',
            firmId: firmId,
            name: 'Category $suffix',
          ),
        );
    await db
        .into(db.units)
        .insert(
          UnitsCompanion.insert(
            id: 'unit-$suffix',
            firmId: firmId,
            name: 'Box $suffix',
            symbol: 'box',
          ),
        );
    await db
        .into(db.items)
        .insert(
          ItemsCompanion.insert(
            id: 'item-$suffix',
            firmId: firmId,
            name: 'Widget $suffix',
          ),
        );
    await db
        .into(db.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            id: 'movement-$suffix',
            firmId: firmId,
            itemId: 'item-$suffix',
            kind: 'opening',
            quantity: 10,
            source: 'opening_balance',
            date: now,
          ),
        );
    await db
        .into(db.salesInvoices)
        .insert(
          SalesInvoicesCompanion.insert(
            id: 'invoice-$suffix',
            firmId: firmId,
            number: 'INV-001',
            invoiceDate: now,
          ),
        );
    await db
        .into(db.salesInvoiceItems)
        .insert(
          SalesInvoiceItemsCompanion.insert(
            id: 'invoice-line-$suffix',
            invoiceId: 'invoice-$suffix',
            name: 'Widget',
            quantity: 1,
            rate: 100,
          ),
        );
    await db
        .into(db.purchaseBills)
        .insert(
          PurchaseBillsCompanion.insert(
            id: 'bill-$suffix',
            firmId: firmId,
            number: 'PUR-001',
            billDate: now,
          ),
        );
    await db
        .into(db.purchaseBillItems)
        .insert(
          PurchaseBillItemsCompanion.insert(
            id: 'bill-line-$suffix',
            billId: 'bill-$suffix',
            name: 'Widget',
            quantity: 1,
            rate: 100,
          ),
        );
    await db
        .into(db.payments)
        .insert(
          PaymentsCompanion.insert(
            id: 'payment-$suffix',
            firmId: firmId,
            type: 'payment_in',
            number: 'RCPT-001',
            amount: 100,
            date: now,
          ),
        );
    await db
        .into(db.expenses)
        .insert(
          ExpensesCompanion.insert(
            id: 'expense-$suffix',
            firmId: firmId,
            number: 'EXP-001',
            category: 'Rent',
            amount: 500,
            date: now,
          ),
        );
    await db
        .into(db.accounts)
        .insert(
          AccountsCompanion.insert(
            id: 'account-$suffix',
            firmId: firmId,
            code: '6001',
            name: 'Rent $suffix',
            type: 'expense',
          ),
        );
    await db
        .into(db.journalEntries)
        .insert(
          JournalEntriesCompanion.insert(
            id: 'journal-$suffix',
            firmId: firmId,
            number: 'JV/0001',
            date: now,
            narration: 'Opening balance $suffix',
          ),
        );
    await db
        .into(db.journalLines)
        .insert(
          JournalLinesCompanion.insert(
            id: 'journal-line-$suffix',
            entryId: 'journal-$suffix',
            accountId: 'account-$suffix',
            debit: const Value(500),
          ),
        );
    await db
        .into(db.appSettings)
        .insert(
          AppSettingsCompanion.insert(
            key: 'books_locked_upto',
            firmId: Value(firmId),
            value: '2026-03-31',
          ),
        );
    await db
        .into(db.syncQueue)
        .insert(
          SyncQueueCompanion.insert(
            id: 'queue-$suffix',
            firmId: Value(firmId),
            entity: 'parties',
            entityId: 'party-$suffix',
            operation: 'insert',
          ),
        );
    await db
        .into(db.auditLogs)
        .insert(
          AuditLogsCompanion.insert(
            id: 'audit-$suffix',
            firmId: Value(firmId),
            action: 'create',
            entity: 'parties',
          ),
        );
    await db
        .into(db.godowns)
        .insert(
          GodownsCompanion.insert(
            id: 'godown-$suffix',
            firmId: firmId,
            name: 'Store $suffix',
          ),
        );
    await db
        .into(db.bankAccounts)
        .insert(
          BankAccountsCompanion.insert(
            id: 'bank-$suffix',
            firmId: firmId,
            name: 'HDFC $suffix',
          ),
        );
    // A loan plus a transaction against it, because the child is the row that
    // is easiest to leave behind: it hangs off the loan rather than naming a
    // firm in any way a casual reader would notice.
    final loan = await db
        .into(db.loans)
        .insertReturning(
          LoansCompanion.insert(
            id: 'loan-$suffix',
            firmId: firmId,
            principalAmount: 50000,
            startDate: now,
          ),
        );
    await db
        .into(db.loanTransactions)
        .insert(
          LoanTransactionsCompanion.insert(
            id: 'loan-txn-$suffix',
            firmId: firmId,
            loanId: loan.id,
            kind: 'disbursement',
            amount: 50000,
            date: now,
          ),
        );
    await db
        .into(db.gstr9Adjustments)
        .insert(
          Gstr9AdjustmentsCompanion.insert(
            id: 'adj-$suffix',
            firmId: firmId,
            schedule: '4.1A',
            description: 'ITC on capex $suffix',
            amount: 1200,
            date: now,
            financialYearStart: DateTime(2026, 4, 1),
          ),
        );
  }

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    await seed(doomed, 'doomed');
    await seed(survivor, 'survivor');
    // A global setting, which belongs to no firm and must survive.
    await db
        .into(db.appSettings)
        .insert(
          AppSettingsCompanion.insert(key: 'onboarding_done', value: 'true'),
        );
  });

  tearDown(() => db.close());

  test('the fixture covers more than a couple of tables', () async {
    // If seeding silently stopped working, every assertion below would pass by
    // finding nothing at all.
    final tables = await tablesWithFirmId();
    expect(tables.length, greaterThan(8));
    expect(await countWhere('parties', "firm_id = '$doomed'"), 1);
  });

  test('purge leaves no row anywhere that belongs to the business', () async {
    await db.firmRepository.purge(doomed);

    for (final table in await tablesWithFirmId()) {
      expect(
        await countWhere(table, "firm_id = '$doomed'"),
        0,
        reason: '$table still holds rows for the deleted business',
      );
    }
  });

  test('line items go with their documents, not just with the firm', () async {
    // These two reference an invoice/bill rather than a firm, so they are the
    // one place the chain has two links.
    await db.firmRepository.purge(doomed);

    expect(
      await countWhere('sales_invoice_items', "invoice_id = '$doomedInvoice'"),
      0,
    );
    expect(
      await countWhere('purchase_bill_items', "bill_id = '$doomedBill'"),
      0,
    );
    expect(await countWhere('journal_lines', "entry_id = 'journal-doomed'"), 0);
  });

  test('the other business is untouched', () async {
    await db.firmRepository.purge(doomed);

    for (final table in await tablesWithFirmId()) {
      expect(
        await countWhere(table, "firm_id = '$survivor'"),
        1,
        reason: '$table lost the surviving business\'s rows',
      );
    }
    final survivorFirm = await db.firmRepository.getById(survivor);
    expect(survivorFirm, isNotNull);
  });

  test('a setting that belongs to no business survives', () async {
    await db.firmRepository.purge(doomed);
    expect(await countWhere('app_settings', "key = 'onboarding_done'"), 1);
  });

  test('the deletion is recorded, and the record outlives the business', () async {
    await db.firmRepository.purge(doomed);

    // Nothing firm-scoped may remain — that includes the deleted business's own
    // audit trail — but the *fact* of the deletion has to be visible somewhere.
    final logs = await (db.select(
      db.auditLogs,
    )..where((t) => t.action.equals('purge'))).get();
    expect(logs, hasLength(1));
    expect(logs.single.firmId, isNull);
    expect(logs.single.summary, contains('Business doomed'));
  });

  test('nothing is queued to tell the server about it', () async {
    // A queued `firms`/delete would be wrong for both modes the UI offers, and
    // would erase itself: the outbox row carries the firm's id, and the purge
    // deletes exactly those rows.
    await db.firmRepository.purge(doomed);

    final queued = await db.select(db.syncQueue).get();
    expect(queued.where((row) => row.entity == 'firms'), isEmpty);
    expect(
      await countWhere('sync_queue', "firm_id = '$doomed'"),
      0,
      reason: 'a queue entry survived for a business that no longer exists',
    );
  });
}
