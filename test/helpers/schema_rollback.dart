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

  /// Sets the file's declared version. Call this last.
  static Future<void> setVersion(AppDatabase db, int version) =>
      db.customStatement('PRAGMA user_version = $version');
}
