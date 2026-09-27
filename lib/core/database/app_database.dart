import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tables/firms.dart';
import 'tables/items.dart';
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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(LazyDatabase(_open));
  AppDatabase.test(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
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
