import 'package:drift/drift.dart';

/// Key/value store for UI and business preferences (one row per firm where
/// the setting is firm-scoped, plus global keys with a null firmId).
@DataClassName('SettingEntity')
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get firmId => text().nullable()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {key, firmId};
}

/// Outbox for the (optional) cloud sync. Writes are enqueued here whenever
/// local data changes; a sync worker drains the queue when online.
@DataClassName('SyncQueueEntity')
class SyncQueue extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().nullable()();
  TextColumn get entity => text()(); // table/entity name
  TextColumn get entityId => text()();

  /// insert | update | delete
  TextColumn get operation => text()();
  TextColumn get payload => text().nullable()(); // JSON snapshot
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  TextColumn get error => text().nullable()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Append-only audit trail. Every create/update/delete/restore of business
/// data writes one row — who did what, when, to which record, with the
/// changed summary. Never updated or deleted (purge only with the firm).
@DataClassName('AuditLogEntity')
class AuditLogs extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().nullable()();

  /// Who performed the action (local user name; remote identity when synced).
  TextColumn get actor => text().nullable()();

  /// create | update | delete | restore | purge | lock | unlock | login
  TextColumn get action => text()();

  /// Table/entity name: sales_invoices, parties, items, payments, expenses,
  /// purchases, settings, firms.
  TextColumn get entity => text()();
  TextColumn get entityId => text().nullable()();

  /// Human summary, e.g. "Invoice INV-001 for ₹1,332.22".
  TextColumn get summary => text().nullable()();

  /// JSON diff/snapshot where cheap (field names + before/after scalars).
  TextColumn get details => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Device/user identities for multi-user firms (local roster; synced later).
@DataClassName('FirmMemberEntity')
class FirmMembers extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();
  TextColumn get name => text()();
  TextColumn get email => text().nullable()();
  TextColumn get role => text().withDefault(
    const Constant('admin'),
  )(); // admin | staff | accountant
  TextColumn get userId => text().nullable()(); // remote identity when synced
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Salted hash of this member's PIN. Null means no PIN is set, and — since
  /// the whole feature is opt-in — no PIN is set on a firm that never turned
  /// it on.
  ///
  /// Never the PIN itself, and never exported: see `SettingsRepository`'s
  /// `_neverExportedColumns`. A PIN is a password, and a backup file is
  /// something people email to themselves.
  TextColumn get pinHash => text().nullable()();

  /// Per-member random salt, so two members with the same PIN do not produce
  /// the same hash and a stolen file cannot be attacked with precomputed
  /// digests.
  TextColumn get pinSalt => text().nullable()();

  /// A deactivated member cannot sign in and keeps their history, rather than
  /// being deleted — audit rows reference them.
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}
