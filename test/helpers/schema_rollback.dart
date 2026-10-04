import 'package:atria/core/database/app_database.dart';

/// Rolls a database file back so a migration test can replay the upgrade.
///
/// **This list has to be updated every time a migration lands.** A test that
/// only drops the columns its *own* version added stops testing anything the
/// moment a later migration runs: the chain then tries to add a column that is
/// already there and dies on `duplicate column name`, which looks like a broken
/// migration and is actually a stale test.
///
/// Each block is versioned so it is obvious which step a new column belongs to.
class SchemaRollback {
  SchemaRollback._();

  /// Drops everything the v12 banking/loans/TDS migration added.
  ///
  /// `loan_transactions` goes before `loans` for the same reason the purge
  /// does: the foreign key points at it, and dropping the parent first leaves a
  /// child nothing to point at.
  static Future<void> bankingV12(AppDatabase db) async {
    await db.customStatement('DROP TABLE IF EXISTS loan_transactions');
    await db.customStatement('DROP TABLE IF EXISTS loans');
    await db.customStatement('DROP TABLE IF EXISTS bank_accounts');
    await db.customStatement('DROP TABLE IF EXISTS gstr9_adjustments');
    await db.customStatement(
      'ALTER TABLE payments DROP COLUMN bank_account_id',
    );
    await db.customStatement('ALTER TABLE expenses DROP COLUMN item_id');
    await db.customStatement(
      'ALTER TABLE purchase_bills DROP COLUMN deductee_pan',
    );
    await db.customStatement(
      'ALTER TABLE purchase_bills DROP COLUMN tds_section',
    );
    await db.customStatement(
      'ALTER TABLE purchase_bills DROP COLUMN tds_section_rate',
    );
  }

  /// Drops everything the v11 costing migration added.
  ///
  /// `godowns` is a whole table, and its index goes with it.
  static Future<void> costingV11(AppDatabase db) async {
    await db.customStatement('DROP TABLE IF EXISTS godowns');
    await db.customStatement(
      'ALTER TABLE stock_movements DROP COLUMN unit_cost',
    );
    await db.customStatement(
      'ALTER TABLE stock_movements DROP COLUMN source_line_id',
    );
    await db.customStatement(
      'ALTER TABLE stock_movements DROP COLUMN godown_id',
    );
    await db.customStatement('ALTER TABLE items DROP COLUMN costing_method');
    await db.customStatement('ALTER TABLE items DROP COLUMN default_godown_id');
    await db.customStatement('ALTER TABLE parties DROP COLUMN category_id');
  }

  /// Drops everything the v10 local-PIN migration added.
  static Future<void> localUsersV10(AppDatabase db) async {
    await db.customStatement('ALTER TABLE firm_members DROP COLUMN pin_hash');
    await db.customStatement('ALTER TABLE firm_members DROP COLUMN pin_salt');
    await db.customStatement('ALTER TABLE firm_members DROP COLUMN is_active');
  }

  /// Drops everything the v9 quotation-lifecycle migration added.
  static Future<void> quotationLifecycleV9(AppDatabase db) async {
    await db.customStatement(
      'ALTER TABLE sales_invoices DROP COLUMN converted_to_invoice_id',
    );
    await db.customStatement(
      'ALTER TABLE sales_invoices DROP COLUMN converted_at',
    );
  }

  /// Rolls back to just before v10 — everything from v9 up.
  ///
  /// The common case for a test that wants to prove a v10-or-later chain: it
  /// wants a file as a v9 build left it, and every step since has to be undone
  /// for the replay to reach it.
  static Future<void> afterV8(AppDatabase db) async {
    await costingV11(db);
    await localUsersV10(db);
  }

  /// Everything from v10 up, for a test that wants a file as a v10 build left
  /// it. The v12 test uses this; the three older tests each call
  /// [bankingV12] next to their own hand-rolled drops instead, because each
  /// reaches a different version and hiding that behind one helper would make
  /// the rollback invisible.
  static Future<void> afterV9(AppDatabase db) async {
    await bankingV12(db);
    await costingV11(db);
    await localUsersV10(db);
  }

  /// Sets the file's declared version. Call this last.
  static Future<void> setVersion(AppDatabase db, int version) =>
      db.customStatement('PRAGMA user_version = $version');
}
