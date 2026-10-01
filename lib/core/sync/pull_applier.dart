import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../api/sync_client.dart';
import '../database/app_database.dart';

/// The outcome of applying one pull page, for logging and tests.
class PullApplyReport {
  const PullApplyReport({
    this.applied = 0,
    this.skipped = 0,
    this.highestSeq = 0,
  });

  /// Changes written into the local database.
  final int applied;

  /// Changes recognised as already-present (this device's own echo, a row the
  /// local copy already supersedes, or something this version cannot apply)
  /// and deliberately not re-applied.
  final int skipped;

  /// The highest journal sequence this page advanced the cursor to.
  final int highestSeq;
}

/// Applies a pulled journal page into the local database.
///
/// The push half sends *state* (the row as the device has it); the pull half
/// replays *history* (the row as each device had it when it saved). Replaying
/// history needs an answer to "what if the same row changed on both devices?",
/// and this class answers it with one rule, applied the same way everywhere:
///
/// **Row-level last-write-wins on `updated_at`.** A pulled row overwrites the
/// local row only when the pulled row's `updated_at` is strictly newer.
/// Anything older is history the local device has already superseded —
/// applying it would silently undo a newer local edit. A missing or
/// unparseable `updated_at` counts as old, so a malformed payload can never
/// win, and a row the local device has never seen is always inserted.
///
/// The rule is per *row*, not per document: an invoice saved on two devices
/// converges to whichever save was later. This keeps the applier
/// table-agnostic, which is what lets it replay any entity without per-table
/// merge code — and without the server ever holding row state to arbitrate.
///
/// Four structural facts make this safe rather than merely plausible:
///
/// * **The journal is ordered.** Pages arrive by per-firm sequence, so a
///   document's insert is always applied before the updates that follow it,
///   and the last write the applier sees *is* the newest.
/// * **Payloads are whole rows.** Each change carries every column, so an
///   apply is one insert or update — no field-by-field patching, no
///   half-merged rows.
/// * **No `INSERT OR REPLACE`, ever.** SQLite's REPLACE deletes the
///   conflicting row first, which fires `ON DELETE CASCADE` and would wipe an
///   invoice's line items on every parent update. Upserts are an explicit
///   existence check plus UPDATE or INSERT.
/// * **Children are insert-if-absent.** `sales_invoice_items`,
///   `purchase_bill_items`, `journal_lines` and `stock_movements` have no
///   `updated_at` of their own and are never updated by the app — an edit
///   deletes and re-inserts the set with fresh ids. The applier mirrors that:
///   a child already present is left alone, so re-delivered pages cannot
///   duplicate lines.
///
/// A change that cannot apply (an unknown entity, a child whose parent has
/// not arrived) is skipped and the cursor still advances: one poison row must
/// wedge neither this pull nor every pull after it.
class PullApplier {
  PullApplier(this._db);

  final AppDatabase _db;

  /// Tables whose rows may be applied. Everything else in a page is skipped:
  /// the journal is device-authored, and an entity name that does not map to
  /// a synced table must never reach raw SQL interpolated into a query.
  static const Set<String> _supportedEntities = {
    'firms',
    'parties',
    'items',
    'categories',
    'units',
    'sales_invoices',
    'sales_invoice_items',
    'purchase_bills',
    'purchase_bill_items',
    'payments',
    'expenses',
    'accounts',
    'journal_entries',
    'journal_lines',
    'stock_movements',
  };

  /// Child tables: keyed by their own `id`, no `updated_at`, insert-if-absent.
  static const Set<String> _childEntities = {
    'sales_invoice_items',
    'purchase_bill_items',
    'journal_lines',
    'stock_movements',
  };

  /// Applies [page] for [firmId]. Returns what happened, including the new
  /// cursor value — the highest sequence seen, applied or not, because a
  /// change this device declines must never be re-fetched for ever.
  Future<PullApplyReport> applyPage({
    required String firmId,
    required PullPage page,
  }) async {
    var applied = 0;
    var skipped = 0;
    var highest = 0;

    for (final change in page.changes) {
      if (change.seq > highest) highest = change.seq;
      final ok = await _applyOne(firmId, change);
      if (ok) {
        applied++;
      } else {
        skipped++;
      }
    }

    return PullApplyReport(
      applied: applied,
      skipped: skipped,
      highestSeq: highest,
    );
  }

  /// Applies one change. Returns false when it was correctly ignored.
  Future<bool> _applyOne(String firmId, JournaledChange change) async {
    if (!_supportedEntities.contains(change.entity)) return false;
    if (change.operation != 'insert' &&
        change.operation != 'update' &&
        change.operation != 'delete') {
      return false;
    }

    try {
      final payload = change.payload;

      if (change.operation == 'delete') {
        // A tombstone. Soft-delete is a state a *row* carries (is_deleted),
        // so a journal delete means the row was removed outright — the
        // permanent-delete paths only: the recycle bin's purge, and a firm
        // erased from another device (whose local row dies with its
        // cascades).
        await _hardDelete(change.entity, change.entityId);
        return true;
      }

      if (payload == null) {
        // An update whose row had already gone at push time: nothing to apply.
        return false;
      }

      // Every non-firm payload must belong to the firm it was journalled
      // under. Forcing the payload's own firm_id (when it carries one) to
      // agree with the journal's is what stops a row from landing in the
      // wrong books.
      final rowFirm = payload['firm_id'];
      if (change.entity != 'firms' &&
          rowFirm is String &&
          rowFirm.isNotEmpty &&
          rowFirm != firmId) {
        return false;
      }

      if (_childEntities.contains(change.entity)) {
        final applied = await _insertChildIfAbsent(change.entity, payload);
        return applied;
      }
      final applied = await _upsertParent(change.entity, payload);
      return applied;
    } on Object catch (failure, stack) {
      // A change that throws (an FK orphan mid-page, a column shape this
      // version cannot store) is skipped rather than allowed to stop the
      // pull: the cursor advances, the books keep converging, and the next
      // page is not held hostage by one row. Logged loudly, because a skip
      // that nobody can see is how books quietly diverge.
      debugPrint(
        'atria sync: skipped ${change.entity}/${change.entityId} '
        '(seq ${change.seq}): $failure\n$stack',
      );
      return false;
    }
  }

  /// Parent tables: row-level last-write-wins, then insert or update.
  Future<bool> _upsertParent(
    String entity,
    Map<String, Object?> payload,
  ) async {
    final id = payload['id'];
    if (id is! String || id.isEmpty) return false;
    final table = _tableNamed(entity);
    if (table == null) return false;

    final existing = await _fetchRow(entity, id);
    if (existing != null) {
      final pulledAt = _parseUpdatedAt(payload['updated_at']);
      final localAt = _parseUpdatedAt(existing['updated_at']);
      // No usable pulled timestamp counts as old: never overwrite.
      if (pulledAt == null) return false;
      if (localAt != null && !pulledAt.isAfter(localAt)) return false;
      await _writeRow(table, payload, mode: _WriteMode.update);
    } else {
      await _writeRow(table, payload, mode: _WriteMode.insert);
    }
    return true;
  }

  /// Children: insert when absent, never update. See the class comment.
  Future<bool> _insertChildIfAbsent(
    String entity,
    Map<String, Object?> payload,
  ) async {
    final id = payload['id'];
    if (id is! String || id.isEmpty) return false;
    if (await _rowExists(entity, id)) return false;
    final table = _tableNamed(entity);
    if (table == null) return false;
    await _writeRow(table, payload, mode: _WriteMode.insert);
    return true;
  }

  /// A missing or malformed `updated_at` parses to null = "old".
  ///
  /// Both sides of the comparison must be interpreted identically or the
  /// comparison is fiction. What travels is what the push normalised: raw
  /// seconds (drift's storage) multiplied into milliseconds, with no zone
  /// conversion anywhere — the writer stamped `DateTime.now()` and the epoch
  /// value is zone-independent from there. So this parses numbers back with
  /// the same no-zone rule rather than assuming UTC, which would skew every
  /// comparison by the device's offset and let an older write win.
  DateTime? _parseUpdatedAt(Object? raw) {
    if (raw is num) {
      // Two producers share this column: the push normalised drift's seconds
      // out to milliseconds, while the local row read returns raw seconds
      // (drift's storage). Both are epoch numbers, so telling them apart is a
      // magnitude test: anything under 10^11 is seconds (that boundary is
      // year 5138 in seconds and February 1973 in milliseconds, so every real
      // timestamp lands unambiguously on one side). Getting this wrong is not
      // a cosmetic skew: local 2026 parsed as ms becomes 1970, and every
      // pulled change - however old - beats it.
      final ms = raw.toInt() < 100000000000 ? raw.toInt() * 1000 : raw.toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (raw is String && raw.isNotEmpty) {
      // ISO strings from a device that pushed its payload directly; a value
      // with an explicit offset parses to it, one without is read as local —
      // matching how the writer created it.
      return DateTime.tryParse(raw);
    }
    return null;
  }

  Future<Map<String, Object?>?> _fetchRow(String entity, String id) async {
    final row = await _db
        .customSelect(
      'SELECT * FROM $entity WHERE id = ? LIMIT 1',
      variables: [Variable.withString(id)],
    )
        .getSingleOrNull();
    return row?.data;
  }

  Future<bool> _rowExists(String entity, String id) async {
    return await _fetchRow(entity, id) != null;
  }

  Future<void> _hardDelete(String entity, String id) async {
    final table = _tableNamed(entity);
    if (table == null) return;
    await _db.customUpdate(
      'DELETE FROM $entity WHERE id = ?',
      variables: [Variable.withString(id)],
      updates: {table},
    );
  }

  TableInfo<Table, dynamic>? _tableNamed(String entity) {
    for (final table in _db.allTables) {
      if (table.actualTableName == entity) return table;
    }
    return null;
  }

  /// Writes [payload] into [table] as an insert or an update by `id`.
  ///
  /// Only columns the table actually declares are written; a payload may
  /// carry extra keys (sent by a newer app version), which are ignored — the
  /// same forward-compatibility rule as skipping an unknown entity, and the
  /// reason an upgraded device can still pull from an older one and
  /// vice versa.
  Future<void> _writeRow(
    TableInfo<Table, dynamic> table,
    Map<String, Object?> payload, {
    required _WriteMode mode,
  }) async {
    final bySqlName = {
      for (final column in table.$columns) column.name: column,
    };
    final values = <String, Object?>{};
    for (final entry in payload.entries) {
      final column = bySqlName[entry.key];
      if (column == null) continue;
      values[entry.key] = _coerce(column, entry.value);
    }
    if (values.isEmpty) return;

    final columns = values.keys.toList(growable: false);
    final id = values['id'];

    // The variable list is built to match the SQL's placeholder order, which
    // differs per mode: INSERT binds every column in order; UPDATE binds the
    // SET columns (id excluded) and then the WHERE id. Building one list and
    // patching it per mode is how a placeholder-count mismatch happens.
    final List<Variable<Object>> variables;
    switch (mode) {
      case _WriteMode.insert:
        variables = [
          for (final name in columns) _variableFor(values[name]),
        ];
      case _WriteMode.update:
        variables = [
          for (final name in columns)
            if (name != 'id') _variableFor(values[name]),
          if (id != null) Variable<String>('$id'),
        ];
    }

    final String sql;
    switch (mode) {
      case _WriteMode.insert:
        final placeholders = List.filled(columns.length, '?').join(', ');
        sql = 'INSERT INTO ${table.actualTableName} '
            '(${columns.join(', ')}) VALUES ($placeholders)';
      case _WriteMode.update:
        if (id == null) return;
        final assignments = [
          for (final name in columns)
            if (name != 'id') '$name = ?',
        ];
        if (assignments.isEmpty) return;
        sql = 'UPDATE ${table.actualTableName} '
            'SET ${assignments.join(', ')} WHERE id = ?';
    }

    await _db.customUpdate(sql, variables: variables, updates: {table});
  }

  /// Payload values arrive as drift's JSON shapes; SQLite wants its own.
  /// Only the two types drift encodes differently are touched — everything
  /// else (text, reals, ints, nulls) passes through.
  Object? _coerce(GeneratedColumn<Object?> column, Object? value) {
    if (value == null) return null;
    switch (column.type) {
      case DriftSqlType.bool:
        // Push normalised 0/1 out to true/false; bring them back.
        if (value is bool) return value ? 1 : 0;
        if (value is num) return value == 1 ? 1 : 0;
        if (value is String) return value == 'true' || value == '1' ? 1 : 0;
        return value;
      case DriftSqlType.dateTime:
        // Push normalised seconds out to milliseconds (or ISO strings);
        // drift stores seconds.
        if (value is num) return value ~/ 1000;
        if (value is String) {
          final parsed = DateTime.tryParse(value);
          if (parsed != null) return parsed.millisecondsSinceEpoch ~/ 1000;
        }
        return value;
      default:
        return value;
    }
  }

  Variable<Object> _variableFor(Object? value) {
    // A null must bind as SQL NULL. This once fell through to
    // Variable<String>('null'), which SQLite accepted silently and stored as
    // the four characters "null" in every nullable column of every pulled
    // row - harmless in a text column, and a crash at typed-read time in an
    // int column (drift parses it with int.parse). The round-trip test
    // exists because hand-built payloads that simply omit nullable columns
    // never catch this class of bug.
    if (value == null) return Variable<Object>(null);
    if (value is bool) return Variable<bool>(value);
    if (value is int) return Variable<int>(value);
    if (value is double) return Variable<double>(value);
    if (value is String) return Variable<String>(value);
    return Variable<String>('$value');
  }
}

enum _WriteMode { insert, update }
