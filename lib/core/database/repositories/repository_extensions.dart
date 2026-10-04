import 'package:drift/drift.dart';

import '../app_database.dart';
import 'audit_repository.dart';
import 'firm_repository.dart';
import 'item_repository.dart';
import 'ledger_repository.dart';
import 'party_repository.dart';
import 'payment_repository.dart';
import 'purchase_repository.dart';
import 'report_repository.dart';
import 'sales_repository.dart';
import 'settings_repository.dart';

/// Scoped access to the repositories for a single firm.
///
/// Keeps the "current firm" in one place so feature code never has to thread
/// a firm id through every call.
extension DatabaseRepositories on AppDatabase {
  FirmRepository get firmRepository => FirmRepository(this);

  PartyRepository partyRepositoryFor(String firmId) =>
      PartyRepository(this, firmId);

  ItemRepository itemRepositoryFor(String firmId) =>
      ItemRepository(this, firmId);

  SalesRepository salesRepositoryFor(String firmId) =>
      SalesRepository(this, firmId);

  PurchaseRepository purchaseRepositoryFor(String firmId) =>
      PurchaseRepository(this, firmId);

  PaymentRepository paymentRepositoryFor(String firmId) =>
      PaymentRepository(this, firmId);

  ExpenseRepository expenseRepositoryFor(String firmId) =>
      ExpenseRepository(this, firmId);

  ReportRepository reportRepositoryFor(String firmId) =>
      ReportRepository(this, firmId);

  /// Chart of accounts, journal vouchers and the ledger reports.
  LedgerRepository ledgerRepositoryFor(String firmId) =>
      LedgerRepository(this, firmId);

  SettingsRepository get settingsRepository => SettingsRepository(this);
  BackupRepository get backupRepository => BackupRepository(this);

  /// Append-only audit trail. Read through [AuditRepository.list]; write
  /// through [AuditRepository.log] (repositories call it on mutations).
  AuditRepository get auditRepository => AuditRepository(this);

  /// The firm's period-lock boundary, read straight from settings (used by
  /// repositories before mutating documents dated in the past).
  Future<DateTime?> booksLockedUpto(String firmId) async {
    // A global row (firmId NULL) and a firm-scoped row can both exist for
    // this key; getSingleOrNull() would throw on the pair and abort every
    // save. Order newest-first and take one — mirrors SettingsRepository.get.
    final query = select(appSettings)
      ..where((t) =>
          t.key.equals('books_locked_upto') &
          (t.firmId.equals(firmId) | t.firmId.isNull()))
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    final raw = row?.value;
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// Throws when [date] is inside the locked period. The single enforcement
  /// point — the duplicate [PeriodLock.assertDateEditable] in
  /// audit_repository.dart is a thin alias kept for its nicer typed error.
  Future<void> assertDateEditable(String firmId, DateTime date) async {
    final locked = await booksLockedUpto(firmId);
    if (locked == null) return;
    final day = DateTime(date.year, date.month, date.day);
    if (!day.isAfter(locked)) {
      throw Exception(
          'Books are locked through ${locked.day}/${locked.month}/'
          '${locked.year}. Unlock the period in Settings to change earlier '
          'transactions.');
    }
  }

  /// Convenience write-through used by the seeder and bootstrap code.
  Future<void> settingsSet(String key, String value, {String? firmId}) =>
      settingsRepository.set(key, value, firmId: firmId);

  Future<String?> settingsGet(String key, {String? firmId}) =>
      settingsRepository.get(key, firmId: firmId);
}
