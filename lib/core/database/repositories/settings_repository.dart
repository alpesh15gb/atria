import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/member_role.dart';
import '../app_database.dart';
import '../../constants/app_constants.dart';
import '../../utils/file_names.dart';
import 'sync_mixin.dart';

/// Key/value settings store, firm-scoped where relevant.
class SettingsRepository with SyncQueueMixin {
  SettingsRepository(this.db);

  @override
  final AppDatabase db;

  Future<String?> get(String key, {String? firmId}) async {
    final query = db.select(db.appSettings)
      ..where(
        (t) =>
            t.key.equals(key) &
            (firmId == null ? t.firmId.isNull() : t.firmId.equals(firmId)),
      )
      // Order + limit so a duplicate row (see [set]) can never make this a
      // multi-row query — getSingleOrNull() throws on more than one row.
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.value;
  }

  Future<bool> getBool(
    String key, {
    String? firmId,
    bool fallback = false,
  }) async {
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
      await (db.delete(db.appSettings)..where(
            (t) =>
                t.key.equals(key) &
                (firmId == null ? t.firmId.isNull() : t.firmId.equals(firmId)),
          ))
          .go();
      await db
          .into(db.appSettings)
          .insert(
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

  Future<void> setInt(String key, int value, {String? firmId}) =>
      set(key, '$value', firmId: firmId);

  Future<void> remove(String key, {String? firmId}) async {
    final query = db.delete(db.appSettings)
      ..where(
        (t) =>
            t.key.equals(key) &
            (firmId == null ? t.firmId.isNull() : t.firmId.equals(firmId)),
      );
    await query.go();
  }

  // ---- Global preference keys ----
  static const String kThemeMode = 'theme_mode'; // system | light | dark
  static const String kActiveFirmId = 'active_firm_id';
  static const String kOnboardingDone = 'onboarding_done';
  static const String kSeededDemo = 'seeded_demo';
  static const String kSyncEnabled = 'sync_enabled';

  /// When the outbox last drained successfully, ISO-8601 UTC.
  static const String kSyncLastPushedAt = 'sync_last_pushed_at';

  /// When the last full sync (push + pull) completed, ISO-8601 UTC. Kept
  /// apart from [kSyncLastPushedAt] because a pull can succeed after a push
  /// that failed, and "last synced" should mean both directions.
  static const String kSyncLastSyncedAt = 'sync_last_synced_at';

  /// Per-firm pull cursors, `sync_cursor_<firmId>` -> highest applied seq.
  /// Managed by SyncEngine; documented here so the key family stays findable.
  /// Comma-separated ids of the firms this device has registered on the server.
  ///
  /// The journal's rows carry a foreign key to `firms`, so a push for a firm the
  /// server has never heard of fails on a constraint the operator cannot act on.
  /// Registering is one extra round trip per firm, once per install.
  static const String kSyncRegisteredFirms = 'sync_registered_firms';
  static const String kSupabaseUrl = 'supabase_url';
  static const String kSupabaseAnonKey = 'supabase_anon_key';

  // ---- Apex Books server (see core/api/api_config.dart) ----
  /// Overrides the built-in production address. Global: the server a person
  /// signs in to is not a per-firm choice.
  static const String kApiBaseUrl = 'api_base_url';

  /// Stable id for this install, minted once and never changed — refresh
  /// tokens are bound to it.
  static const String kDeviceId = 'device_id';

  /// Human label shown in the device list, captured once.
  static const String kDeviceName = 'device_name';
  static const String kLastBackupAt = 'last_backup_at';
  static const String kUserName = 'user_name';

  /// The signed-in account's address. See [ServerSession].
  static const String kUserEmail = 'user_email';
  static const String kFirstRun = 'first_run';

  // ---- Signed-in session (see core/api/server_session.dart) ----
  ///
  /// Written only by sign-in, read only by [ServerSession]. Nothing here is a
  /// per-firm value: the account a device is signed in to is not a choice the
  /// user makes per business.
  ///
  /// **These are stored in plaintext.** `app_settings` is an ordinary SQLite
  /// table, so a stolen device or a copied database file yields a live session.
  /// The fix is an OS-backed store (DPAPI on Windows, the Android Keystore),
  /// which is a separate piece of work; keeping all four keys behind one class
  /// is what makes it a change in one place rather than a hunt.
  static const String kAccessToken = 'access_token';
  static const String kRefreshToken = 'refresh_token';

  /// ISO-8601 UTC instant, so an expired token is not mistaken for a session.
  static const String kAccessTokenExpiresAt = 'access_token_expires_at';
}

/// Full-app JSON backup & restore (offline-first local export).
class BackupRepository {
  BackupRepository(this.db);

  final AppDatabase db;

  static const int _version = 3;
  // v3: the ledger (`accounts`, `journal_entries`, `journal_lines`) and
  // `audit_logs` joined the export, and the sign-in keys were filtered out of
  // it in both directions. A v1/v2 file is still restorable — it simply has no
  // ledger keys, and [importFromJson] counts a missing section as zero rows
  // rather than failing — so this only ever rejects a *newer* file.

  /// Global (`firm_id IS NULL`) settings that never travel in a backup — in
  /// either direction.
  ///
  /// The export is written to a plaintext JSON file that the backup screen
  /// hands to `Share.shareXFiles`, and the sign-in keys live in the very same
  /// global settings rows, so exporting them turns "back up my books" into
  /// "publish my session": anybody the file reaches can use the access token,
  /// and the refresh token is bound to [SettingsRepository.kDeviceId], which
  /// travels right beside it. Restoring a colleague's backup then signs *this*
  /// device in as them, with no password and no prompt.
  ///
  /// Hence both halves: the keys are dropped on the way out, and dropped again
  /// on the way in, so a file taken before this existed cannot authenticate a
  /// fresh install either. Firm-scoped settings are unaffected — a per-firm
  /// preference is part of the books, and none of these keys is ever
  /// firm-scoped.
  static const Set<String> _neverExported = {
    SettingsRepository.kAccessToken,
    SettingsRepository.kRefreshToken,
    SettingsRepository.kAccessTokenExpiresAt,
    SettingsRepository.kDeviceId,
    SettingsRepository.kUserEmail,
    SettingsRepository.kUserName,
  };

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
    // Built in a loop rather than with `cols.map`, because a stripped column
    // must be *absent* from the map, not present with a null value. The two
    // look the same to `jsonEncode` and are not the same at all: `"pin_hash":
    // null` still names the field, so an attacker reading the file learns
    // which build wrote it and where to aim, and a hand-edited file could carry
    // a value that later merges back in.
    final out = <String, Object?>{};
    cols.forEach((key, expr) {
      // Dropped on the way out, before the value is even read. This is a
      // column-level strip rather than an entry in [_neverExported] because
      // that set is keyed by *settings key*, and `firm_members` has no key
      // column — it is a table, not a key/value store. A PIN hash is a
      // password, and a backup file is something people mail to themselves and
      // paste into cloud storage; the member's name, email and role are part
      // of the books, the credentials are not.
      if (_neverExportedColumns.contains(key)) return;
      if (expr is Variable) {
        out[key] = _jsonSafe(expr.value);
        return;
      }
      if (expr is Constant) {
        out[key] = _jsonSafe(expr.value);
        return;
      }
      throw StateError(
        'Backup: unsupported column expression for "$key" — refusing to '
        'export it as null.',
      );
    });
    return out;
  }

  /// Columns stripped from every exported row, whatever table it is in.
  ///
  /// The complement of [_neverExported]: that set removes whole settings
  /// *rows* by key, this one removes individual *columns* by name. Both are
  /// needed — the session keys are rows, the PIN material is columns.
  static const Set<String> _neverExportedColumns = {'pin_hash', 'pin_salt'};

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

    final parties = await (db.select(
      db.parties,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final categories = await (db.select(
      db.categories,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final units = await (db.select(
      db.units,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final items = await (db.select(
      db.items,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final stockMovements = await (db.select(
      db.stockMovements,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final godowns = await (db.select(
      db.godowns,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final bankAccounts = await (db.select(
      db.bankAccounts,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final loans = await (db.select(
      db.loans,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final loanTransactions = await (db.select(
      db.loanTransactions,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final gstr9Adjustments = await (db.select(
      db.gstr9Adjustments,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final sales = await (db.select(
      db.salesInvoices,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final salesItems = await (db.select(
      db.salesInvoiceItems,
    )..where((t) => t.invoiceId.isIn(sales.map((s) => s.id).toSet()))).get();
    final purchases = await (db.select(
      db.purchaseBills,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final purchaseItems = await (db.select(
      db.purchaseBillItems,
    )..where((t) => t.billId.isIn(purchases.map((s) => s.id).toSet()))).get();
    final payments = await (db.select(
      db.payments,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final expenses = await (db.select(
      db.expenses,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final members = await (db.select(
      db.firmMembers,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    // The ledger is part of the books: without these four keys a restore onto a
    // new device lost every journal voucher and the whole chart of accounts,
    // and a restore over existing data left the previous firms' accounts and
    // journals behind as orphans pointing at a firm that no longer exists.
    final accounts = await (db.select(
      db.accounts,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    final journalEntries = await (db.select(
      db.journalEntries,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    // Lines hang off their voucher rather than the firm, the same way an
    // invoice line hangs off its invoice.
    final journalLines =
        await (db.select(db.journalLines)..where(
              (t) => t.entryId.isIn(journalEntries.map((e) => e.id).toSet()),
            ))
            .get();
    final auditLogs = await (db.select(
      db.auditLogs,
    )..where((t) => t.firmId.isIn(firmIds))).get();
    // Firm-scoped settings travel with the books; the global rows carry the
    // sign-in session, which must never reach a shareable file — see
    // [_neverExported].
    final settings =
        await (db.select(db.appSettings)..where(
              (t) =>
                  (t.firmId.isIn(firmIds) | t.firmId.isNull()) &
                  t.key.isNotIn(_neverExported),
            ))
            .get();

    return {
      'app': AppConstants.appName,
      'version': _version,
      'exportedAt': DateTime.now().toIso8601String(),
      'firms': firms.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'parties': parties.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'categories': categories
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'units': units.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'items': items.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'stock_movements': stockMovements
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'godowns': godowns.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'bank_accounts': bankAccounts
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'loans': loans.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'loan_transactions': loanTransactions
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'gstr9_adjustments': gstr9Adjustments
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'sales_invoices': sales
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'sales_invoice_items': salesItems
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'purchase_bills': purchases
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'purchase_bill_items': purchaseItems
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'payments': payments.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'expenses': expenses.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'firm_members': members
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'accounts': accounts.map((e) => _rowToMap(e.toCompanion(true))).toList(),
      'journal_entries': journalEntries
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'journal_lines': journalLines
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'audit_logs': auditLogs
          .map((e) => _rowToMap(e.toCompanion(true)))
          .toList(),
      'settings': settings.map((e) => _rowToMap(e.toCompanion(true))).toList(),
    };
  }

  /// Writes the backup to the app documents directory, returns the path.
  Future<String> exportToFile({String? firmId, String? fileName}) async {
    final data = await export(firmId: firmId);
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(dir.path, 'apexbooks', 'backups'));
    if (!backupDir.existsSync()) {
      backupDir.createSync(recursive: true);
    }
    final name =
        fileName ??
        'apexbooks-backup-${DateTime.now().toIso8601String().split('T').first}';
    final file = File(
      p.join(
        backupDir.path,
        '${sanitizeFileName(name, fallback: 'apexbooks-backup')}.json',
      ),
    );
    await file.writeAsString(jsonEncode(data), flush: true);
    return file.path;
  }

  /// Replaces all local data with the contents of [json].
  /// Returns the number of rows restored.
  ///
  /// Throws [FormatException] WITHOUT touching the database when [json] is
  /// not an Apex Books backup — validation must run before any destructive write.
  Future<int> importFromJson(Map<String, dynamic> json) async {
    // Checked before validation, and both before the transaction: a restore
    // replaces every firm's data, so it is the single most destructive write
    // in the app and the one most worth refusing by role.
    db.assertPermission(Permission.restoreBackup);
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
      count += await _restore(
        db.salesInvoiceItems,
        json['sales_invoice_items'],
      );
      count += await _restore(db.purchaseBills, json['purchase_bills']);
      count += await _restore(
        db.purchaseBillItems,
        json['purchase_bill_items'],
      );
      count += await _restore(db.payments, json['payments']);
      count += await _restore(db.expenses, json['expenses']);
      count += await _restore(db.firmMembers, json['firm_members']);
      // Before items and movements, which can name a godown. A backup written
      // before v11 has no `godowns` key at all — restoring it then leaves every
      // reference null, which is the same state a single-location firm is in,
      // so the older file restores correctly rather than failing.
      count += await _restore(db.godowns, json['godowns']);
      // Before `payments` and `loans`, which can name a bank account or a
      // loan. A backup written before v12 has none of these keys, and each
      // `_restore` treats a missing key as "nothing to restore" rather than as
      // an error — an older file restores correctly instead of failing on a
      // null the schema never had.
      count += await _restore(db.bankAccounts, json['bank_accounts']);
      // Loan transactions before loans, for the same children-first reason the
      // journal lines above give.
      count += await _restore(db.loanTransactions, json['loan_transactions']);
      count += await _restore(db.loans, json['loans']);
      count += await _restore(db.gstr9Adjustments, json['gstr9_adjustments']);
      // Children before parents: journal lines reference their voucher, and
      // vouchers reference a firm that the first line above has restored.
      count += await _restore(db.accounts, json['accounts']);
      count += await _restore(db.journalEntries, json['journal_entries']);
      count += await _restore(db.journalLines, json['journal_lines']);
      count += await _restore(db.auditLogs, json['audit_logs']);
      // A backup taken before the session keys were filtered out of the export
      // still carries them, and writing them back is the same hole in reverse:
      // it would sign this device in as whoever made the file.
      count += await _restore(
        db.appSettings,
        json['settings'],
        skipKeys: _neverExported,
      );
    });
    return count;
  }

  /// Verifies [json] is an Apex Books backup this version can restore. Public so
  /// the restore screen can reject a wrong file before showing the
  /// destructive "Replace all data?" confirmation.
  static void validateBackupJson(Map<String, dynamic> json) {
    // Backups written before the rename carry the old marker. They are the same
    // format and the same data — refusing them would make every archive a
    // customer had already taken worthless on the day they upgraded.
    const acceptedMarkers = {'Apex Books', 'atria'};
    if (!acceptedMarkers.contains(json['app'])) {
      throw const FormatException(
        'This file is not an Apex Books backup (missing the "app" '
        'marker). Nothing was restored.',
      );
    }
    final version = json['version'];
    if (version is! int) {
      throw const FormatException(
        'Backup file has no readable version. Nothing was restored.',
      );
    }
    if (version > _version) {
      throw FormatException(
        'This backup was created by a newer version of Apex Books '
        '(backup v$version, app v$_version). Update the app and try '
        'again. Nothing was restored.',
      );
    }
    final firms = json['firms'];
    if (firms is! List || firms.isEmpty) {
      throw const FormatException(
        'The backup contains no firms to restore. Nothing was restored.',
      );
    }
    final ids = firms
        .whereType<Map>()
        .map((f) => f['id'])
        .whereType<String>()
        .toSet();
    if (ids.isEmpty) {
      throw const FormatException(
        'The backup\'s firm rows have no ids. Nothing was restored.',
      );
    }
  }

  /// Inserts [rows] into [table], returning how many landed.
  ///
  /// [skipKeys] drops a row whose `key` column value is listed — used by the
  /// settings restore to refuse the sign-in keys (see [_neverExported]); every
  /// other table is inserted whole. A missing or malformed section restores
  /// nothing and is not an error, which is how a v1/v2 backup (written before
  /// the ledger keys existed) still restores correctly.
  Future<int> _restore(
    TableInfo table,
    dynamic rows, {
    Set<String>? skipKeys,
  }) async {
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
      if (skipKeys != null && skipKeys.contains(values['key'])) continue;
      final vars = <Variable>[];
      for (final col in columns) {
        // Stripped on the way in as well as on the way out. The export is the
        // belt; this is the braces — a backup written by a build that did not
        // strip yet, or a file edited by hand, would otherwise write somebody's
        // PIN hash straight back onto a row and leave it there.
        if (_neverExportedColumns.contains(col)) {
          vars.add(const Variable(null));
          continue;
        }
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
    // `loan_transactions.loan_id` is a real foreign key, so the schedule goes
    // before the loan it hangs off. The payments above come first for the same
    // reason: a repayment records the payment it settled.
    await db.delete(db.loanTransactions).go();
    await db.delete(db.loans).go();
    await db.delete(db.gstr9Adjustments).go();
    // `bank_accounts` is named by `payments.bankAccountId` and
    // `bank_accounts.ledgerAccountId`, both of which point at accounts — so it
    // goes after `accounts` below, not here. Listed here anyway to make the
    // ordering explicit rather than incidental.
    await db.delete(db.stockMovements).go();
    await db.delete(db.items).go();
    await db.delete(db.units).go();
    await db.delete(db.categories).go();
    await db.delete(db.parties).go();
    // The ledger used to be absent from this list altogether, so restoring over
    // existing books left every chart of accounts and journal voucher behind as
    // an orphan pointing at a firm that no longer exists. Lines hang off their
    // voucher, vouchers off the firm, so children go first.
    await db.delete(db.journalLines).go();
    await db.delete(db.journalEntries).go();
    await db.delete(db.accounts).go();
    await db.delete(db.appSettings).go();
    await db.delete(db.firmMembers).go();
    // `godowns` is referenced by `items.defaultGodownId` and
    // `stock_movements.godownId`, so it goes before those two — and before
    // `firms`, which it does carry a real foreign key to.
    await db.delete(db.godowns).go();
    // `ledger_account_id` points at `accounts`, so this goes after it and
    // before the firms.
    await db.delete(db.bankAccounts).go();
    // `audit_logs.firm_id` is nullable and carries no foreign key, so nothing
    // would ever remove these for us — the same reason eraseFirmRows deletes
    // them explicitly. Before the firms whose actions they record.
    await db.delete(db.auditLogs).go();
    await db.delete(db.firms).go();
    // Outbox entries reference entity ids that no longer exist after a
    // full replace — they would push deleted/updated ghosts upstream.
    await db.delete(db.syncQueue).go();
  }
}
