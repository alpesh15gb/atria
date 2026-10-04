import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tables/firms.dart';
import 'tables/items.dart';
import 'tables/ledger.dart';
import 'tables/parties.dart';
import 'tables/purchases.dart';
import 'tables/sales_invoices.dart';
import 'tables/settings.dart';

part 'app_database.g.dart';

/// Offline-first local source of truth.
///
/// Every write goes through a Drift transaction and enqueues an entry in
/// [SyncQueue] so an optional cloud sync can drain it later without changing
/// any calling code.
@DriftDatabase(
  tables: [
    Firms,
    FirmMembers,
    Parties,
    Categories,
    Units,
    Items,
    StockMovements,
    SalesInvoices,
    SalesInvoiceItems,
    PurchaseBills,
    PurchaseBillItems,
    Payments,
    Expenses,
    AppSettings,
    SyncQueue,
    AuditLogs,
    Accounts,
    JournalEntries,
    JournalLines,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(LazyDatabase(_open));
  AppDatabase.test(super.e);

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          // drift has no `onDowngrade`: its MigrationStrategy doc says
          // "Schema version upgrades and downgrades will both be run here", so
          // a downgrade arrives with `from > to` and every `from < N` step below
          // is simply skipped — which leaves the build opening a file newer
          // than the code understands, failing later in whichever screen
          // happened to touch an added column first, with an error the person
          // cannot act on. Refusing here keeps the books intact and says what
          // to do about it.
          if (from > to) {
            throw StateError(
              'This database was created by a newer version of Atria '
              '(schema v$from, this build understands v$to). Put the newer '
              'version back, or restore a backup taken with this version.',
            );
          }
          // v2: recycle-bin soft-delete columns + document series for the
          // returns suite (credit/debit/delivery notes). All additive with
          // defaults, so existing rows migrate in place.
          if (from < 2) {
            await m.addColumn(parties, parties.isDeleted);
            await m.addColumn(parties, parties.deletedAt);
            await m.addColumn(items, items.isDeleted);
            await m.addColumn(items, items.deletedAt);
            await m.addColumn(firms, firms.creditNotePrefix);
            await m.addColumn(firms, firms.debitNotePrefix);
            await m.addColumn(firms, firms.deliveryNotePrefix);
            await m.addColumn(firms, firms.creditNoteSequence);
            await m.addColumn(firms, firms.debitNoteSequence);
            await m.addColumn(firms, firms.deliveryNoteSequence);
          }
          // v3: document recycle bin (deletedAt on the four document tables)
          // + the append-only audit trail.
          if (from < 3) {
            await m.addColumn(salesInvoices, salesInvoices.deletedAt);
            await m.addColumn(purchaseBills, purchaseBills.deletedAt);
            await m.addColumn(payments, payments.deletedAt);
            await m.addColumn(expenses, expenses.deletedAt);
            await m.createTable(auditLogs);
          }
          // v4: per-FY sequence reset support + hot-path indexes and the
          // (firmId, docType, number) uniqueness that backs transactional
          // numbering. createAll skips existing tables, so the index
          // definitions are applied explicitly for upgraded databases.
          if (from < 4) {
            await m.addColumn(firms, firms.sequenceFy);
            await m.createIndex(idxSalesFirmDate);
            await m.createIndex(idxSalesParty);
            await m.createIndex(idxPurchaseFirmDate);
            await m.createIndex(idxPurchaseParty);
            await m.createIndex(idxPaymentsFirmDate);
            await m.createIndex(idxPaymentsParty);
            await m.createIndex(idxPaymentsLinked);
            await m.createIndex(idxExpensesFirmDate);
            await m.createIndex(idxPartiesFirmName);
            await m.createIndex(idxItemsFirmName);
            await m.createIndex(idxMovementsFirmDate);
            await m.createIndex(idxMovementsItem);
            await m.createIndex(idxMovementsSource);
          }
          // v5: the purchase-order series (Vyapar imports land POs as
          // documents; the app previously had no series to number new ones).
          // Additive with defaults, so existing rows migrate in place.
          if (from < 5) {
            await m.addColumn(firms, firms.purchaseOrderPrefix);
            await m.addColumn(firms, firms.purchaseOrderSequence);
          }
          // v6: tax deducted/collected at source, and the cheque lifecycle.
          // All additive with defaults, so existing rows migrate in place. Note
          // what is *not* here: no stored amount is recomputed. A document
          // issued before this version keeps the totals it was issued with, and
          // the new columns only describe documents saved from now on.
          if (from < 6) {
            await m.addColumn(salesInvoices, salesInvoices.tcsRate);
            await m.addColumn(purchaseBills, purchaseBills.tdsRate);
            await m.addColumn(payments, payments.chequeStatus);
            await m.addColumn(payments, payments.depositedAt);
            await m.addColumn(payments, payments.bouncedAt);
            await m.addColumn(payments, payments.bounceReason);
          }
          // v7: the chart of accounts and journal vouchers. New tables only,
          // so an upgraded database keeps every existing row and picks up its
          // chart the first time the ledger is opened (LedgerRepository
          // .ensureChart seeds it on demand rather than in the migration, so a
          // firm created later gets one too).
          if (from < 7) {
            await m.createTable(accounts);
            await m.createTable(journalEntries);
            await m.createTable(journalLines);
            await m.createIndex(uqAccountsCode);
            await m.createIndex(idxAccountsFirmType);
            await m.createIndex(uqJournalNumber);
            await m.createIndex(idxJournalFirmDate);
            await m.createIndex(idxJournalLinesEntry);
            await m.createIndex(idxJournalLinesAccount);
          }
        },
      );

  /// Opens the database lazily. [getApplicationSupportDirectory] is async, but
  /// [NativeDatabase.createInBackground] wants a synchronous [File], so the
  /// whole executor is deferred until first use.
  static Future<QueryExecutor> _open() async {
    return NativeDatabase.createInBackground(
      await _file(),
      setup: (db) {
        // WAL mode improves write throughput for the transactional writes
        // this app performs continuously.
        db.execute('PRAGMA journal_mode=WAL;');
        db.execute('PRAGMA foreign_keys=ON;');
      },
    );
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    final dbDir = Directory(p.join(dir.path, 'atria'));
    if (!dbDir.existsSync()) {
      dbDir.createSync(recursive: true);
    }
    return File(p.join(dbDir.path, 'atria.db'));
  }

  /// Path used by backup/restore and by the demo seeder.
  static Future<File> dbFile() => _file();
}
