import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/member_role.dart';
import '../../utils/id_utils.dart';
import '../app_database.dart';
import 'settings_repository.dart';

/// Append-only audit trail. Never updated, never deleted (except with the
/// firm's data wipe). One row per business-data mutation.
class AuditRepository {
  AuditRepository(this.db);

  final AppDatabase db;

  Future<void> log({
    required String action,
    required String entity,
    String? firmId,
    String? actor,
    String? entityId,
    String? summary,
    Map<String, Object?>? details,
  }) async {
    await db
        .into(db.auditLogs)
        .insert(
          AuditLogsCompanion.insert(
            // Must not be derived from the clock alone. Windows reports time in
            // coarse ticks, so two entries written back to back (a bulk import,
            // the demo seeder) came out with the same id and the second one hit
            // the primary key.
            id: 'aud_${IdUtils.newId()}',
            firmId: Value(firmId),
            actor: Value(actor),
            action: action,
            entity: entity,
            entityId: Value(entityId),
            summary: Value(summary),
            details: Value(details == null ? null : jsonEncode(details)),
          ),
        );
  }

  Future<void> simple({
    required String action,
    required String entity,
    String? firmId,
    String? entityId,
    String? summary,
  }) {
    return log(
      action: action,
      entity: entity,
      firmId: firmId,
      entityId: entityId,
      summary: summary,
    );
  }

  /// Newest-first trail for one firm (global rows included), optionally
  /// filtered to one entity type.
  Future<List<AuditLogEntity>> list({
    String? firmId,
    String? entity,
    int limit = 500,
  }) {
    final query = db.select(db.auditLogs);
    if (firmId != null) {
      query.where((t) => t.firmId.isNull() | t.firmId.equals(firmId));
    }
    if (entity != null) {
      query.where((t) => t.entity.equals(entity));
    }
    query
      // rowid DESC as the tiebreaker: createdAt has second granularity, so
      // two entries written in the same second would otherwise order
      // arbitrarily and flip the trail.
      ..orderBy([
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.rowId),
      ])
      ..limit(limit);
    return query.get();
  }
}

/// Books closing: transactions dated on or before [booksLockedUpto] can no
/// longer be created, edited or deleted. Backdated-into-locked-period saves
/// are refused by the repositories via [assertDateEditable].
class PeriodLock {
  PeriodLock(this._settings);

  final SettingsRepository _settings;

  static const String kBooksLockedUpto = 'books_locked_upto';

  /// The lock boundary (inclusive), or null when books are open.
  Future<DateTime?> lockedUpto({String? firmId}) async {
    final raw = await _settings.get(kBooksLockedUpto, firmId: firmId);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// Freezes books through [date], in either direction.
  ///
  /// Guarded, because moving the lock is the one write that unlocks every
  /// other guard: a role that cannot edit a locked document can become able to
  /// by rolling the boundary back. Checked before the write, for the same
  /// reason the document guards are — the session is in-memory, so a refusal
  /// has nothing to roll back.
  Future<void> lockThrough(DateTime date, {String? firmId}) async {
    _settings.db.assertPermission(Permission.managePeriodLock);
    await _settings.set(
      kBooksLockedUpto,
      DateTime(date.year, date.month, date.day).toIso8601String(),
      firmId: firmId,
    );
  }

  Future<void> unlock({String? firmId}) async {
    _settings.db.assertPermission(Permission.managePeriodLock);
    await _settings.remove(kBooksLockedUpto, firmId: firmId);
  }

  /// Throws [PeriodLockedException] when [date] falls inside the locked
  /// period. Repositories call this before any write whose document date
  /// matters. Unlocking the check is deliberate: reads and reports always
  /// work; only mutations are frozen.
  Future<void> assertDateEditable(DateTime date, {String? firmId}) async {
    final locked = await lockedUpto(firmId: firmId);
    if (locked == null) return;
    final day = DateTime(date.year, date.month, date.day);
    if (!day.isAfter(locked)) {
      throw PeriodLockedException(locked, date);
    }
  }
}

/// Thrown when a write would mutate books inside a locked period.
class PeriodLockedException implements Exception {
  PeriodLockedException(this.lockedThrough, this.attempted);

  final DateTime lockedThrough;
  final DateTime attempted;

  String get message =>
      'Books are locked through '
      '${lockedThrough.day}/${lockedThrough.month}/${lockedThrough.year}. '
      'Unlock the period in Settings to change earlier transactions.';

  @override
  String toString() => message;
}
