import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_database.dart';
import 'sync_mixin.dart';

/// Key/value settings store, firm-scoped where relevant.
class SettingsRepository with SyncQueueMixin {
  SettingsRepository(this.db);

  @override
  final AppDatabase db;

  Future<String?> get(String key, {String? firmId}) async {
    final query = db.select(db.appSettings)
      ..where((t) =>
          t.key.equals(key) &
          (firmId == null ? t.firmId.isNull() : t.firmId.equals(firmId)))
      // Order + limit so a duplicate row (see [set]) can never make this a
      // multi-row query — getSingleOrNull() throws on more than one row.
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.value;
  }

  Future<bool> getBool(String key, {String? firmId, bool fallback = false}) async {
    final v = await get(key, firmId: firmId);
    if (v == null) return fallback;
    return v == 'true' || v == '1';
  }

  Future<int?> getInt(String key, {String? firmId, int? fallback}) async {
    final v = await get(key, firmId: firmId);
    if (v == null) return fallback;
    return int.tryParse(v);
  }

  Future<void> set(String key, String value, {String? firmId}) async {
    // The composite PK is (key, firmId) with firmId NULLABLE, and SQLite
    // treats NULLs as distinct in a primary key — so INSERT OR REPLACE finds
    // no conflict for global keys and appends a duplicate every write. The
    // next read would then hit getSingleOrNull() and throw. Delete the
    // existing row(s) for this key first, inside one transaction.
    await db.transaction(() async {
      await (db.delete(db.appSettings)
            ..where((t) =>
                t.key.equals(key) &
                (firmId == null ? t.firmId.isNull() : t.firmId.equals(firmId))))
          .go();
      await db.into(db.appSettings).insert(
            SettingEntity(
              key: key,
              firmId: firmId,
              value: value,
              updatedAt: DateTime.now(),
            ),
          );
    });
  }

  Future<void> setBool(String key, bool value, {String? firmId}) =>
      set(key, value ? 'true' : 'false', firmId: firmId);

  Future<void> remove(String key, {String? firmId}) async {
    final query = db.delete(db.appSettings)
      ..where((t) =>
          t.key.equals(key) &
          (firmId == null ? t.firmId.isNull() : t.firmId.equals(firmId)));
    await query.go();
  }

  // ---- Global preference keys ----
  static const String kThemeMode = 'theme_mode'; // system | light | dark
  static const String kActiveFirmId = 'active_firm_id';
  static const String kOnboardingDone = 'onboarding_done';
  static const String kSeededDemo = 'seeded_demo';
  static const String kSyncEnabled = 'sync_enabled';
  static const String kSupabaseUrl = 'supabase_url';
  static const String kSupabaseAnonKey = 'supabase_anon_key';
  static const String kLastBackupAt = 'last_backup_at';
  static const String kUserName = 'user_name';
  static const String kUserEmail = 'user_email';
  static const String kFirstRun = 'first_run';
}

/// Full-app JSON backup & restore (offline-first local export).
class BackupRepository {
  BackupRepository(this.db);

  final AppDatabase db;

  static const int _version = 2;

  /// Serializes a whole row to plain JSON-safe values.
  ///
  /// Reads the value out of each drift `Variable` in the companion's column
  /// map — the previous `expr is Constant` check never matched (companions
  /// wrap values in `Variable`, not `Constant`), so every exported field was
  /// `null` and a restore either hit NOT-NULL failures or, after a validation
  /// gap, wiped the database with nulls. Anything that is not a simple
  /// variable is a bug: throw instead of silently exporting null.
  Map<String, Object?> _rowToMap(Insertable entity) {
    final cols = entity.toColumns(true);
    return cols.map((key, expr) {
      if (expr is Variable) return MapEntry(key, _jsonSafe(expr.value));
      if (expr is Constant) return MapEntry(key, _jsonSafe(expr.value));
      throw StateError(
          'Backup: unsupported column expression for "$key" — refusing to '
          'export it as null.');
    });
  }

  /// JSON cannot encode [DateTime]/[Uint8List] — convert to strings.
  Object? _jsonSafe(Object? v) {
    if (v is DateTime) return v.toIso8601String();
    if (v is Uint8List) return base64Encode(v);
    return v;
  }

  Future<Map<String, dynamic>> export({String? firmId}) async {
    final firms = firmId == null
        ? await db.select(db.firms).get()
        : await (db.select(db.firms)..where((t) => t.id.equals(firmId))).get();
    final firmIds = firms.map((f) => f.id).toSet();

    final parties = await (db.select(db.parties)
          ..where((t) => t.firmId.isIn(firmIds)))
        .get();
    final categories = await (db.select(db.categories)
          ..where((t) => t.firmId.isIn(firmIds)))
        .get();
    final units = await (db.select(db.units)
          ..where((t) => t.firmId.isIn(firmIds)))
        .get();
    final items = await (db.select(db.items)
          ..where((t) => t.firmId.isIn(firmIds)))
        .get();
    final stockMovements = await (db.select(db.stockMovements)
          ..where((t) => t.firmId.isIn(firmIds)))
        .get();
    final sales = await (db.select(db.salesInvoices)
          ..where((t) => t.firmId.isIn(firmIds)))
        .get();
    final salesItems = await (db.select(db.salesInvoiceItems)
          ..where((t) => t.invoiceId.isIn(sales.map((s) => s.id).toSet())))
        .get();
    final purchases = await (db.select(db.purchaseBills)
          ..where((t) => t.firmId.isIn(firmIds)))
        .get();
    final purchaseItems = await (db.select(db.purchaseBillItems)
          ..where((t) => t.billId.isIn(purchases.map((s) => s.id).toSet())))
        .get();
    final payments = await (db.select(db.payments)
          ..where((t) => t.firmId.isIn(firmIds)))
        .get();
    final expenses = await (db.select(db.expenses)
          ..where((t) => t.firmId.isIn(firmIds)))
        .get();
    final members = await (db.select(db.firmMembers)
          ..where((t) => t.firmId.isIn(firmIds)))
        .get();
    final settings = await (db.select(db.appSettings)
          ..where((t) => t.firmId.isIn(firmIds) | t.firmId.isNull()))
        .get();

    return {
      'app': 'atria',
      'version': _version,
      'exportedAt': DateTime.now().toIso8601String(),
      'firms': firms.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'parties': parties.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'categories':
          categories.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'units': units.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'items': items.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'stock_movements':
          stockMovements.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'sales_invoices':
          sales.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'sales_invoice_items':
          salesItems.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'purchase_bills':
          purchases.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'purchase_bill_items':
          purchaseItems.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'payments': payments.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'expenses': expenses.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'firm_members':
          members.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'settings': settings.map((e) => _rowToMap(e.toCompanion(true))).toList(),
    };
  }

  /// Writes the backup to the app documents directory, returns the path.
  Future<String> exportToFile({String? firmId, String? fileName}) async {
    final data = await export(firmId: firmId);
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(dir.path, 'atria', 'backups'));
    if (!backupDir.existsSync()) {
      backupDir.createSync(recursive: true);
    }
    final name = fileName ??
        'atria-backup-${DateTime.now().toIso8601String().split('T').first}';
    final file = File(p.join(backupDir.path, '$name.json'));
    await file.writeAsString(jsonEncode(data), flush: true);
    return file.path;
  }

  /// Replaces all local data with the contents of [json].
  /// Returns the number of rows restored.
  ///
  /// Throws [FormatException] WITHOUT touching the database when [json] is
  /// not an Atria backup — validation must run before any destructive write.
  Future<int> importFromJson(Map<String, dynamic> json) async {
    validateBackupJson(json);

    var count = 0;
    await db.transaction(() async {
      await _clearAll();

      count += await _restore(db.firms, json['firms']);
      count += await _restore(db.parties, json['parties']);
      count += await _restore(db.categories, json['categories']);
      count += await _restore(db.units, json['units']);
      count += await _restore(db.items, json['items']);
      count += await _restore(db.stockMovements, json['stock_movements']);
      count += await _restore(db.salesInvoices, json['sales_invoices']);
      count +=
          await _restore(db.salesInvoiceItems, json['sales_invoice_items']);
      count += await _restore(db.purchaseBills, json['purchase_bills']);
      count +=
          await _restore(db.purchaseBillItems, json['purchase_bill_items']);
      count += await _restore(db.payments, json['payments']);
      count += await _restore(db.expenses, json['expenses']);
      count += await _restore(db.firmMembers, json['firm_members']);
      count += await _restore(db.appSettings, json['settings']);
    });
    return count;
  }

  /// Verifies [json] is an Atria backup this version can restore. Public so
  /// the restore screen can reject a wrong file before showing the
  /// destructive "Replace all data?" confirmation.
  static void validateBackupJson(Map<String, dynamic> json) {
    if (json['app'] != 'atria') {
      throw const FormatException(
          'This file is not an Atria backup (missing the "app: atria" '
          'marker). Nothing was restored.');
    }
    final version = json['version'];
    if (version is! int) {
      throw const FormatException(
          'Backup file has no readable version. Nothing was restored.');
    }
    if (version > _version) {
      throw FormatException(
          'This backup was created by a newer version of Atria '
          '(backup v$version, app v$_version). Update the app and try '
          'again. Nothing was restored.');
    }
    final firms = json['firms'];
    if (firms is! List || firms.isEmpty) {
      throw const FormatException(
          'The backup contains no firms to restore. Nothing was restored.');
    }
    final ids = firms
        .whereType<Map>()
        .map((f) => f['id'])
        .whereType<String>()
        .toSet();
    if (ids.isEmpty) {
      throw const FormatException(
          'The backup\'s firm rows have no ids. Nothing was restored.');
    }
  }

  Future<int> _restore(TableInfo table, dynamic rows) async {
    if (rows is! List) return 0;
    // Restoring from plain JSON means we have raw column values, not a
    // companion, so the insert is written as parameterized SQL. `OR REPLACE`
    // keeps a repeated restore idempotent instead of failing on PK conflicts.
    final columns = table.columnsByName.keys.toList();
    final columnsByName = table.columnsByName;
    final placeholder = List.filled(columns.length, '?').join(', ');
    final sql =
        'INSERT OR REPLACE INTO ${table.actualTableName} (${columns.join(', ')}) '
        'VALUES ($placeholder)';
    var n = 0;
    for (final row in rows) {
      if (row is! Map) continue;
      final values = row.cast<String, Object?>();
      final vars = <Variable>[];
      for (final col in columns) {
        vars.add(Variable(_sqlValue(columnsByName[col], values[col])));
      }
      await db.customInsert(sql, variables: vars, updates: {table});
      n++;
    }
    return n;
  }

  /// Converts a JSON value into the raw SQL form drift stores for [col].
  ///
  /// JSON datetimes are ISO-8601 strings; drift's default storage for
  /// DateTime columns is unix seconds (an int). Bools are stored as 0/1.
  /// Passing raw strings/bools through would corrupt every datetime column
  /// on the first restore.
  Object? _sqlValue(GeneratedColumn? col, Object? v) {
    if (v == null) return null;
    if (col != null && col.type == DriftSqlType.dateTime) {
      final DateTime dt;
      if (v is int) {
        dt = DateTime.fromMillisecondsSinceEpoch(v);
      } else if (v is String) {
        dt = DateTime.parse(v);
      } else {
        return v;
      }
      return dt.millisecondsSinceEpoch ~/ 1000;
    }
    if (v is bool) return v ? 1 : 0;
    return v;
  }

  Future<void> _clearAll() async {
    await db.delete(db.salesInvoiceItems).go();
    await db.delete(db.purchaseBillItems).go();
    await db.delete(db.salesInvoices).go();
    await db.delete(db.purchaseBills).go();
    await db.delete(db.payments).go();
    await db.delete(db.expenses).go();
    await db.delete(db.stockMovements).go();
    await db.delete(db.items).go();
    await db.delete(db.units).go();
    await db.delete(db.categories).go();
    await db.delete(db.parties).go();
    await db.delete(db.appSettings).go();
    await db.delete(db.firmMembers).go();
    await db.delete(db.firms).go();
    // Outbox entries reference entity ids that no longer exist after a
    // full replace — they would push deleted/updated ghosts upstream.
    await db.delete(db.syncQueue).go();
  }
}
