import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/member_role.dart';
import 'tables/firms.dart';
import 'tables/godowns.dart';
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
    Godowns,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(LazyDatabase(_open));
  AppDatabase.test(super.e);

  @override
  int get schemaVersion => 11;

  /// Who is operating, for local-user permissions.
  ///
  /// **Defaults to [MemberSession.off], and that default is the feature.** With
  /// no session set, [assertPermission] grants everything, so a firm that
  /// never turned local users on behaves exactly as it always has — no gate,
  /// no picker, no check. There is no "enable" code path that has to be
  /// remembered; the opt-in is what sets this.
  ///
  /// A field rather than a constructor argument because the database outlives
  /// any one screen, and a repository is handed `this.db` at construction —
  /// the alternative is threading a session through eleven repositories and
  /// every factory that builds them.
  MemberSession session = MemberSession.off;

  /// The permission check every repository write goes through.
  ///
  /// Beside [assertDateEditable] on purpose, and for the same reason: a guard
  /// the UI can forget is not a guard. A repository method is reachable from
  /// sync, from a background job and from a test, none of which pass through
  /// a button.
  void assertPermission(Permission permission) {
    if (!session.allows(permission)) {
      throw PermissionDeniedException(
        permission,
        role: session.role,
        memberName: session.name,
      );
    }
  }

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
          'This database was created by a newer version of Apex Books '
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
      // v8: printed-document layout, and the GSTIN snapshot a payment
      // receipt needs. Both additive with defaults, so existing rows
      // migrate in place: every firm keeps printing the layout it has
      // always printed (`classic`), and payments that predate this keep
      // a null GSTIN rather than a fabricated one.
      if (from < 8) {
        await m.addColumn(firms, firms.pdfTemplate);
        await m.addColumn(payments, payments.partyGstin);
      }
      // v9: the quotation lifecycle. `status` stops carrying "converted"
      // — that overwrote the document's real lifecycle — and the link to
      // the invoice a document became is stored instead. Additive and
      // nullable, so existing rows keep whatever lifecycle they had and
      // gain two nulls.
      if (from < 9) {
        await m.addColumn(salesInvoices, salesInvoices.convertedToInvoiceId);
        await m.addColumn(salesInvoices, salesInvoices.convertedAt);
      }
      // v10: optional local PINs. All nullable with a default, so every
      // existing member row migrates in place and keeps working — a member
      // with no PIN cannot sign in, and a firm that never turned local users
      // on is unaffected.
      if (from < 10) {
        await m.addColumn(firmMembers, firmMembers.pinHash);
        await m.addColumn(firmMembers, firmMembers.pinSalt);
        await m.addColumn(firmMembers, firmMembers.isActive);
      }
      // v11: costing. `unitCost` on every movement is what makes an item's
      // profit report possible at all — until now, stock was valued at the
      // item's *current* purchase price, so a historical P&L moved whenever
      // somebody bought the item. Additive with defaults: existing movements
      // come back with `unitCost = 0`, which is NOT "free" — it is "unknown
      // until replayed", and [CostingBackfill] walks the log to fill it in.
      // The backfill is one-shot and idempotent: it skips any movement that
      // already has a non-zero cost, so running it twice cannot double-count.
      if (from < 11) {
        await m.addColumn(stockMovements, stockMovements.unitCost);
        await m.addColumn(stockMovements, stockMovements.sourceLineId);
        await m.addColumn(stockMovements, stockMovements.godownId);
        await m.addColumn(items, items.costingMethod);
        await m.addColumn(items, items.defaultGodownId);
        await m.addColumn(parties, parties.categoryId);
        await m.createTable(godowns);
        // Explicit, because `createAll` skips a table that already exists and
        // therefore never applies this table's `@TableIndex` to an upgraded
        // database. Same reason as the v4 block above.
        await m.createIndex(idxGodownsFirm);
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

  /// Where the books live under the platform's app-support directory.
  ///
  /// Renamed from `atria` when the product became Apex Books. Everything in
  /// that folder belongs to one business's ledger, so the rename cannot simply
  /// pick a new path — see [adoptLegacyDataDir], which moves the old folder
  /// across on first launch. Without it every existing install would open an
  /// empty set of books and read as a first run.
  ///
  /// This only reaches installs that keep the *same* app-support root. On
  /// Windows that root is shared across the machine's user, so an in-place
  /// upgrade finds its books. On Android it is private to the application id,
  /// and the rename also changed that id (`com.atria.atria` ->
  /// `com.apexbooks.app`), so Android starts the new app in a fresh directory
  /// and the old package's data is unreachable by design. An Android operator
  /// upgrading across the rename has to restore a backup — which is why
  /// [validateBackupJson] accepts pre-rename backups.
  static const String dataDirName = 'apexbooks';

  /// The pre-rename folder, kept only so [adoptLegacyDataDir] can find it.
  /// Do not write here again.
  static const String _legacyDirName = 'atria';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    adoptLegacyDataDir(dir.path);
    final dbDir = Directory(p.join(dir.path, dataDirName));
    if (!dbDir.existsSync()) {
      dbDir.createSync(recursive: true);
    }
    return File(p.join(dbDir.path, '$dataDirName.db'));
  }

  /// Moves a pre-rename `atria/` folder to `apexbooks/` on first launch.
  ///
  /// Only when the new folder does not exist. That condition is what makes this
  /// safe to run on every launch: once the folder is there — migrated, or
  /// created fresh by an install that never had the old one — this returns
  /// immediately and never touches live data.
  ///
  /// The old folder is *moved*, not copied, so a failed launch cannot leave two
  /// diverging ledgers and leave the operator choosing between them. If the
  /// move throws partway the books stay where they were and the next launch
  /// retries, because the new folder still will not exist.
  @visibleForTesting
  static void adoptLegacyDataDir(String supportPath) {
    final newDir = Directory(p.join(supportPath, dataDirName));
    if (newDir.existsSync()) return;

    final oldDir = Directory(p.join(supportPath, _legacyDirName));
    if (!oldDir.existsSync()) return;
    // An empty leftover is not someone's ledger; do not rename a folder the
    // rename itself created on a previous failed attempt.
    if (oldDir.listSync().isEmpty) return;

    try {
      oldDir.renameSync(newDir.path);
    } catch (_) {
      // A cross-volume rename, a locked file, or a permission problem. The
      // books are still in the old folder and still readable; opening a fresh
      // database is far better than refusing to start.
    }
  }

  /// Path used by backup/restore and by the demo seeder.
  static Future<File> dbFile() => _file();
}
