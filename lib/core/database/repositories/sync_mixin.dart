import 'package:drift/drift.dart';

import '../app_database.dart';

/// Enqueues a sync outbox entry so an optional cloud sync can drain it later.
/// No-ops are fine: if sync is never enabled, the queue simply accumulates
/// and is ignored.
///
/// Every entry gets a UNIQUE id (monotonic counter + timestamp): the old
/// `'entity_id_op'` id with insert-or-replace collapsed an insert+update
/// into one row, so a consumer could be told `update` for a record the
/// server never received. Ordering is preserved by the id's sortability.
int _syncSeq = 0;

mixin SyncQueueMixin {
  AppDatabase get db;

  Future<void> enqueue({
    required String firmId,
    required String entity,
    required String entityId,
    required String operation, // insert | update | delete
    String? payload,
  }) async {
    _syncSeq = (_syncSeq + 1) & 0x3FFFFFFF;
    await db.into(db.syncQueue).insert(SyncQueueCompanion.insert(
          id: '${entity}_${entityId}_'
              '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_'
              '${_syncSeq.toRadixString(36)}',
          firmId: Value(firmId),
          entity: entity,
          entityId: entityId,
          operation: operation,
          payload: Value(payload),
          attempts: const Value(0),
        ));
  }
}

/// Common helpers for date-range filters used across reports.
class DateRangeFilter {
  final DateTime start;
  final DateTime end;

  const DateRangeFilter({required this.start, required this.end});

  factory DateRangeFilter.thisMonth() {
    final now = DateTime.now();
    return DateRangeFilter(
      start: DateTime(now.year, now.month, 1),
      end: DateTime(now.year, now.month + 1, 0, 23, 59, 59),
    );
  }

  factory DateRangeFilter.thisFinancialYear() {
    final now = DateTime.now();
    final start =
        now.month >= 4 ? DateTime(now.year, 4, 1) : DateTime(now.year - 1, 4, 1);
    return DateRangeFilter(
      start: start,
      end: DateTime(start.year + 1, 3, 31, 23, 59, 59),
    );
  }

  factory DateRangeFilter.last30Days() {
    final now = DateTime.now();
    return DateRangeFilter(
      start: now.subtract(const Duration(days: 30)),
      end: now,
    );
  }

  factory DateRangeFilter.today() {
    final now = DateTime.now();
    return DateRangeFilter(
      start: DateTime(now.year, now.month, now.day),
      end: DateTime(now.year, now.month, now.day, 23, 59, 59),
    );
  }

  factory DateRangeFilter.allTime() {
    return DateRangeFilter(
      start: DateTime(2000),
      end: DateTime(2100),
    );
  }

  DateRangeFilter copyWith({DateTime? start, DateTime? end}) {
    return DateRangeFilter(start: start ?? this.start, end: end ?? this.end);
  }
}
