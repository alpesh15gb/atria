import 'package:drift/drift.dart';

import '../../utils/id_utils.dart';
import '../../domain/member_role.dart';
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
    db.assertPermission(Permission.manageMasters);
    final id = _newId();
    final now = DateTime.now();
    await db
        .into(db.parties)
        .insert(
          PartiesCompanion.insert(
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
          ),
        );
    await db.auditRepository.log(
      action: 'create',
      entity: 'parties',
      firmId: firmId,
      entityId: id,
      summary: 'Created party $name',
    );
    await enqueue(
      firmId: firmId,
      entity: 'parties',
      entityId: id,
      operation: 'insert',
    );
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

  /// Every live party, name-ordered.
  ///
  /// Pass `limit: 0` for NO cap. The default 500 exists so a picker that only
  /// ever needs a plausible list does not drag a 20 000-row table into memory,
  /// but it silently truncated the Statement of Account: a deep link
  /// `/statements?party=<id>` for the 501st party resolved nothing and the
  /// screen rendered a blank white area with both downloads disabled. A cap a
  /// caller cannot see is a data-loss bug, so screens that must reach every row
  /// ask for 0 explicitly rather than the default changing under them.
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
        (t) =>
            t.name.lower().like(s) |
            t.phone.lower().like(s) |
            t.gstin.lower().like(s),
      );
    }
    if (limit > 0) query.limit(limit);
    return query.get();
  }

  /// Live parties, name-ordered, re-emitted on any write. Uncapped — this is
  /// the Parties list, which must be able to reach every row; see [all] for why
  /// the default cap is a caller-visible decision rather than a library one.
  Stream<List<PartyEntity>> watchAll({String? type, String search = ''}) {
    final query = db.select(db.parties)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    if (type != null) {
      query.where((t) => t.type.equals(type) | t.type.equals('both'));
    }
    if (search.trim().isNotEmpty) {
      final s = '%${search.trim().toLowerCase()}%';
      // GSTIN is searched here for the same reason it is in [all]: the list
      // screen's own hint says "Search name, phone or GSTIN", and a supplier
      // is far more often looked up by the number printed on an invoice.
      query.where(
        (t) =>
            t.name.lower().like(s) |
            t.phone.lower().like(s) |
            t.gstin.lower().like(s),
      );
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
    db.assertPermission(Permission.manageMasters);
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
    db.assertPermission(Permission.softDelete);
    await db.transaction(() async {
      final party = await getById(id);
      await (db.update(
        db.parties,
      )..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).write(
        PartiesCompanion(
          isDeleted: const Value(true),
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await db.auditRepository.log(
        action: 'delete',
        entity: 'parties',
        firmId: firmId,
        entityId: id,
        summary: 'Deleted party ${party?.name ?? id}',
      );
      await enqueue(
        firmId: firmId,
        entity: 'parties',
        entityId: id,
        operation: 'update',
      );
    });
  }

  /// Undo a soft delete from the recycle bin.
  Future<void> restore(String id) async {
    db.assertPermission(Permission.softDelete);
    await db.transaction(() async {
      final party = await getById(id);
      await (db.update(
        db.parties,
      )..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).write(
        PartiesCompanion(
          isDeleted: const Value(false),
          deletedAt: const Value(null),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await db.auditRepository.log(
        action: 'restore',
        entity: 'parties',
        firmId: firmId,
        entityId: id,
        summary: 'Restored party ${party?.name ?? id}',
      );
      await enqueue(
        firmId: firmId,
        entity: 'parties',
        entityId: id,
        operation: 'update',
      );
    });
  }

  /// Permanent delete — only reachable from the recycle bin. Refuses when
  /// ANY document class still references the party (sales, purchases,
  /// payments, expenses' vendor link is by name only, but payments carry a
  /// partyId), so a purge can never leave dangling party references.
  Future<void> deleteForever(String id) async {
    db.assertPermission(Permission.purge);
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
        db.salesInvoices,
        db.salesInvoices.partyId,
        db.salesInvoices.firmId.equals(firmId),
      );
      final purchaseUsed = await usedIn(
        db.purchaseBills,
        db.purchaseBills.partyId,
        db.purchaseBills.firmId.equals(firmId),
      );
      final paymentsUsed = await usedIn(
        db.payments,
        db.payments.partyId,
        db.payments.firmId.equals(firmId),
      );
      if (salesUsed || purchaseUsed || paymentsUsed) {
        throw StateError(
          'This party is used on recorded documents and cannot be removed.',
        );
      }
      await (db.delete(
        db.parties,
      )..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).go();
      await enqueue(
        firmId: firmId,
        entity: 'parties',
        entityId: id,
        operation: 'delete',
      );
      await db.auditRepository.log(
        action: 'purge',
        entity: 'parties',
        firmId: firmId,
        entityId: id,
        summary: 'Permanently deleted party',
      );
    });
  }

  /// Outstanding for a party: net receivable (positive, Dr) or net payable
  /// (negative, Cr). Reflects opening balance, unpaid sales invoices, credit
  /// notes issued, unpaid purchase bills, debit notes issued, and unlinked
  /// (advance or lump-sum) payments. Cancelled documents and bounced cheques
  /// are excluded.
  Future<double> outstandingFor(String partyId) async {
    final sales = db.selectOnly(db.salesInvoices)
      ..addColumns([db.salesInvoices.balanceDue.sum()])
      ..where(
        db.salesInvoices.firmId.equals(firmId) &
            db.salesInvoices.partyId.equals(partyId) &
            db.salesInvoices.docType.equals('invoice') &
            db.salesInvoices.isDeleted.equals(false) &
            db.salesInvoices.status.equals('cancelled').not(),
      );
    final salesRow = await sales.getSingle();
    final salesDue = salesRow.read(db.salesInvoices.balanceDue.sum()) ?? 0.0;

    final creditNotes = db.selectOnly(db.salesInvoices)
      ..addColumns([db.salesInvoices.grandTotal.sum()])
      ..where(
        db.salesInvoices.firmId.equals(firmId) &
            db.salesInvoices.partyId.equals(partyId) &
            db.salesInvoices.docType.equals('credit_note') &
            db.salesInvoices.isDeleted.equals(false) &
            db.salesInvoices.status.equals('cancelled').not(),
      );
    final cnRow = await creditNotes.getSingle();
    final cnTotal = cnRow.read(db.salesInvoices.grandTotal.sum()) ?? 0.0;

    final purchases = db.selectOnly(db.purchaseBills)
      ..addColumns([db.purchaseBills.balanceDue.sum()])
      ..where(
        db.purchaseBills.firmId.equals(firmId) &
            db.purchaseBills.partyId.equals(partyId) &
            db.purchaseBills.docType.equals('bill') &
            db.purchaseBills.isDeleted.equals(false) &
            db.purchaseBills.status.equals('cancelled').not(),
      );
    final purchaseRow = await purchases.getSingle();
    final purchaseDue =
        purchaseRow.read(db.purchaseBills.balanceDue.sum()) ?? 0.0;

    final debitNotes = db.selectOnly(db.purchaseBills)
      ..addColumns([db.purchaseBills.grandTotal.sum()])
      ..where(
        db.purchaseBills.firmId.equals(firmId) &
            db.purchaseBills.partyId.equals(partyId) &
            db.purchaseBills.docType.equals('debit_note') &
            db.purchaseBills.isDeleted.equals(false) &
            db.purchaseBills.status.equals('cancelled').not(),
      );
    final dnRow = await debitNotes.getSingle();
    final dnTotal = dnRow.read(db.purchaseBills.grandTotal.sum()) ?? 0.0;

    final unlinkedPayments = db.select(db.payments)
      ..where(
        (t) =>
            t.firmId.equals(firmId) &
            t.partyId.equals(partyId) &
            t.linkedInvoiceId.isNull() &
            // `isDeleted` is filtered here for the same reason every sibling
            // query above filters it: binned a payment must stop counting the
            // moment it is binned (see PaymentRepository's softDelete contract at
            // payment_repository.dart:208-211). It was the only query in this
            // method that omitted it, so a binned advance kept reducing the
            // party's outstanding — the one figure in the app that must never be
            // wrong.
            t.isDeleted.equals(false) &
            (t.chequeStatus.isNull() | t.chequeStatus.equals('bounced').not()),
      );
    final pList = await unlinkedPayments.get();
    var unlinkedIn = 0.0;
    var unlinkedOut = 0.0;
    for (final p in pList) {
      if (p.type == 'payment_in') {
        unlinkedIn += p.amount;
      } else if (p.type == 'payment_out') {
        unlinkedOut += p.amount;
      }
    }

    final party = await getById(partyId);
    double opening = 0;
    if (party != null) {
      opening =
          party.openingBalance * (party.openingBalanceType == 'dr' ? 1 : -1);
    }
    return opening +
        (salesDue - cnTotal - unlinkedIn) -
        (purchaseDue - dnTotal - unlinkedOut);
  }

  /// Fires whenever anything [outstandingFor] reads is written: the party's own
  /// row, a sales document, a purchase bill or a payment.
  ///
  /// [outstandingFor] is five aggregates over four tables, and drift can only
  /// invalidate a stream that reads ONE statement — there is no single query to
  /// watch. So this is the coarse signal: the same shape as
  /// `providers.itemMovementSignalProvider`, which the app already watches for
  /// the cached `currentStock` balances. Consumers pair it with a re-read, e.g.
  ///
  /// ```dart
  /// Stream<double> watchOutstanding(String partyId) async* {
  ///   yield await outstandingFor(partyId);
  ///   await for (final _ in watchOutstandingChanges()) {
  ///     yield await outstandingFor(partyId);
  ///   }
  /// }
  /// ```
  ///
  /// No polling, and no dependence on a rebuild the nav shell's IndexedStack
  /// never sends.
  Stream<void> watchOutstandingChanges() async* {
    yield* db
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            db.parties,
            db.salesInvoices,
            db.purchaseBills,
            db.payments,
          ]),
        )
        .map((_) {});
  }

  String _newId() => 'pty_${IdUtils.newId()}';
}
