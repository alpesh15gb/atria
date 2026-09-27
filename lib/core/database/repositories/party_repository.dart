import 'package:drift/drift.dart';

import '../app_database.dart';
import 'repository_extensions.dart';
import 'sync_mixin.dart';

/// Customer & supplier management, plus running balances.
class PartyRepository with SyncQueueMixin {
  PartyRepository(this.db, this.firmId);

  @override
  final AppDatabase db;

  final String firmId;

  Future<PartyEntity> create({
    required String name,
    String type = 'customer', // customer | supplier | both
    String? gstin,
    String? pan,
    String gstType = 'unregistered',
    String? contactPerson,
    String? phone,
    String? email,
    String? addressLine1,
    String? addressLine2,
    String? city,
    String? stateCode,
    String? pincode,
    double openingBalance = 0,
    String openingBalanceType = 'dr',
    double? creditLimit,
    int? creditDays,
    String? notes,
  }) async {
    final id = _newId();
    final now = DateTime.now();
    await db.into(db.parties).insert(PartiesCompanion.insert(
          id: id,
          firmId: firmId,
          name: name,
          type: type,
          gstin: Value(gstin?.toUpperCase().trim()),
          pan: Value(pan?.toUpperCase().trim()),
          gstType: Value(gstType),
          contactPerson: Value(contactPerson),
          phone: Value(phone),
          email: Value(email),
          addressLine1: Value(addressLine1),
          addressLine2: Value(addressLine2),
          city: Value(city),
          stateCode: Value(stateCode),
          pincode: Value(pincode),
          openingBalance: Value(openingBalance),
          openingBalanceType: Value(openingBalanceType),
          creditLimit: Value(creditLimit),
          creditDays: Value(creditDays),
          notes: Value(notes),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await db.auditRepository.log(
      action: 'create',
      entity: 'parties',
      firmId: firmId,
      entityId: id,
      summary: 'Created party $name',
    );
    await enqueue(
        firmId: firmId, entity: 'parties', entityId: id, operation: 'insert');
    return (await getById(id))!;
  }

  Future<PartyEntity?> getById(String id) async {
    final query = db.select(db.parties)
      ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
    return query.getSingleOrNull();
  }

  Stream<PartyEntity?> watchById(String id) {
    final query = db.select(db.parties)
      ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
    return query.watchSingleOrNull();
  }

  Future<List<PartyEntity>> all({
    String? type,
    String search = '',
    int limit = 500,
  }) async {
    final query = db.select(db.parties)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    if (type != null) {
      query.where((t) => t.type.equals(type) | t.type.equals('both'));
    }
    if (search.trim().isNotEmpty) {
      final s = '%${search.trim().toLowerCase()}%';
      query.where(
          (t) => t.name.lower().like(s) | t.phone.lower().like(s) | t.gstin.lower().like(s));
    }
    query.limit(limit);
    return query.get();
  }

  Stream<List<PartyEntity>> watchAll({String? type, String search = ''}) {
    final query = db.select(db.parties)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    if (type != null) {
      query.where((t) => t.type.equals(type) | t.type.equals('both'));
    }
    if (search.trim().isNotEmpty) {
      final s = '%${search.trim().toLowerCase()}%';
      query.where(
          (t) => t.name.lower().like(s) | t.phone.lower().like(s));
    }
    return query.watch();
  }

  /// Rows sitting in the recycle bin, newest deletion first.
  Stream<List<PartyEntity>> watchDeleted() {
    final query = db.select(db.parties)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(true))
      ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]);
    return query.watch();
  }

  /// Customers (receivables).
  Stream<List<PartyEntity>> watchCustomers() => watchAll(type: 'customer');

  /// Suppliers (payables).
  Stream<List<PartyEntity>> watchSuppliers() => watchAll(type: 'supplier');

  Future<PartyEntity> update(PartyEntity party) async {
    await db.transaction(() async {
      await db
          .update(db.parties)
          .replace(party.copyWith(updatedAt: DateTime.now()));
      await db.auditRepository.log(
        action: 'update',
        entity: 'parties',
        firmId: firmId,
        entityId: party.id,
        summary: 'Updated party ${party.name}',
      );
      await enqueue(
        firmId: firmId,
        entity: 'parties',
        entityId: party.id,
        operation: 'update',
      );
    });
    return (await getById(party.id))!;
  }

  /// Soft-deletes: the row moves to the recycle bin and disappears from
  /// every list, but documents that reference it keep reading its snapshot
  /// columns (partyName etc. on the invoice rows).
  Future<void> delete(String id) async {
    await db.transaction(() async {
      final party = await getById(id);
      await (db.update(db.parties)
            ..where((t) => t.id.equals(id) & t.firmId.equals(firmId)))
          .write(PartiesCompanion(
        isDeleted: const Value(true),
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ));
      await db.auditRepository.log(
        action: 'delete',
        entity: 'parties',
        firmId: firmId,
        entityId: id,
        summary: 'Deleted party ${party?.name ?? id}',
      );
      await enqueue(
          firmId: firmId, entity: 'parties', entityId: id, operation: 'update');
    });
  }

  /// Undo a soft delete from the recycle bin.
  Future<void> restore(String id) async {
    await db.transaction(() async {
      final party = await getById(id);
      await (db.update(db.parties)
            ..where((t) => t.id.equals(id) & t.firmId.equals(firmId)))
          .write(PartiesCompanion(
        isDeleted: const Value(false),
        deletedAt: const Value(null),
        updatedAt: Value(DateTime.now()),
      ));
      await db.auditRepository.log(
        action: 'restore',
        entity: 'parties',
        firmId: firmId,
        entityId: id,
        summary: 'Restored party ${party?.name ?? id}',
      );
      await enqueue(
          firmId: firmId, entity: 'parties', entityId: id, operation: 'update');
    });
  }

  /// Permanent delete — only reachable from the recycle bin. Refuses when
  /// ANY document class still references the party (sales, purchases,
  /// payments, expenses' vendor link is by name only, but payments carry a
  /// partyId), so a purge can never leave dangling party references.
  Future<void> deleteForever(String id) async {
    await db.transaction(() async {
      Future<bool> usedIn(
        TableInfo table,
        GeneratedColumn<String> partyCol,
        Expression<bool> extra,
      ) async {
        final q = db.selectOnly(table)
          ..addColumns([partyCol])
          ..where(partyCol.equals(id) & extra)
          ..limit(1);
        return await q.getSingleOrNull() != null;
      }

      final salesUsed = await usedIn(
          db.salesInvoices, db.salesInvoices.partyId,
          db.salesInvoices.firmId.equals(firmId));
      final purchaseUsed = await usedIn(
          db.purchaseBills, db.purchaseBills.partyId,
          db.purchaseBills.firmId.equals(firmId));
      final paymentsUsed = await usedIn(
          db.payments, db.payments.partyId,
          db.payments.firmId.equals(firmId));
      if (salesUsed || purchaseUsed || paymentsUsed) {
        throw StateError(
            'This party is used on recorded documents and cannot be removed.');
      }
      await (db.delete(db.parties)
          ..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).go();
      await enqueue(
          firmId: firmId, entity: 'parties', entityId: id, operation: 'delete');
      await db.auditRepository.log(
        action: 'purge',
        entity: 'parties',
        firmId: firmId,
        entityId: id,
        summary: 'Permanently deleted party',
      );
    });
  }

  /// Outstanding for a party: sales invoices unpaid (dr) minus purchase bills
  /// unpaid (cr), plus the opening balance sign. Cancelled documents never
  /// count — their balance columns are zeroed on cancel, and the status
  /// filter here keeps old rows (cancelled before that fix) out too.
  Future<double> outstandingFor(String partyId) async {
    final sales = db.selectOnly(db.salesInvoices)
      ..addColumns([db.salesInvoices.balanceDue.sum()])
      ..where(db.salesInvoices.firmId.equals(firmId) &
          db.salesInvoices.partyId.equals(partyId) &
          db.salesInvoices.docType.equals('invoice') &
          db.salesInvoices.isDeleted.equals(false) &
          db.salesInvoices.status.equals('cancelled').not());
    final salesRow = await sales.getSingle();
    final salesDue =
        salesRow.read(db.salesInvoices.balanceDue.sum()) ?? 0.0;

    final purchases = db.selectOnly(db.purchaseBills)
      ..addColumns([db.purchaseBills.balanceDue.sum()])
      ..where(db.purchaseBills.firmId.equals(firmId) &
          db.purchaseBills.partyId.equals(partyId) &
          db.purchaseBills.docType.equals('bill') &
          db.purchaseBills.isDeleted.equals(false) &
          db.purchaseBills.status.equals('cancelled').not());
    final purchaseRow = await purchases.getSingle();
    final purchaseDue =
        purchaseRow.read(db.purchaseBills.balanceDue.sum()) ?? 0.0;

    final party = await getById(partyId);
    double opening = 0;
    if (party != null) {
      opening = party.openingBalance *
          (party.openingBalanceType == 'dr' ? 1 : -1);
    }
    return opening + salesDue - purchaseDue;
  }

  String _newId() => 'pty_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_${DateTime.now().microsecond}';
}
