import 'package:drift/drift.dart';

import '../../engine/document_numbering.dart';
import '../../utils/id_utils.dart';
import '../app_database.dart';
import 'repository_extensions.dart';
import 'sync_mixin.dart';

/// Creates, lists and switches firms (books of accounts).
class FirmRepository with SyncQueueMixin {
  FirmRepository(this.db);

  @override
  final AppDatabase db;

  Future<FirmEntity> create({
    required String name,
    String? legalName,
    String? gstin,
    String? pan,
    String? stateCode,
    String? addressLine1,
    String? city,
    String? pincode,
    String? phone,
    String? email,
    bool makeDefault = true,
  }) async {
    final id = _uuid;
    final now = DateTime.now();
    await db.into(db.firms).insert(FirmsCompanion.insert(
          id: id,
          name: name,
          legalName: Value(legalName),
          gstin: Value(gstin?.toUpperCase().trim()),
          pan: Value(pan?.toUpperCase().trim()),
          stateCode: Value(stateCode),
          addressLine1: Value(addressLine1),
          city: Value(city),
          pincode: Value(pincode),
          phone: Value(phone),
          email: Value(email),
          isDefault: Value(makeDefault),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    final firm = await getById(id);
    await enqueue(
        firmId: id, entity: 'firms', entityId: id, operation: 'insert');
    return firm!;
  }

  Future<FirmEntity?> getById(String id) async {
    final query = db.select(db.firms)
      ..where((t) => t.id.equals(id));
    return query.getSingleOrNull();
  }

  Stream<FirmEntity?> watchById(String id) {
    final query = db.select(db.firms)
      ..where((t) => t.id.equals(id));
    return query.watchSingleOrNull();
  }

  Future<List<FirmEntity>> all() async {
    final query = db.select(db.firms)
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }

  Stream<List<FirmEntity>> watchAll() {
    final query = db.select(db.firms)
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.watch();
  }

  Future<FirmEntity?> get defaultFirm async {
    final query = db.select(db.firms)
      ..where((t) => t.isDefault.equals(true))
      ..limit(1);
    final result = await query.get();
    if (result.isNotEmpty) return result.first;
    final allFirms = await all();
    return allFirms.isNotEmpty ? allFirms.first : null;
  }

  Future<FirmEntity> update(FirmEntity firm) async {
    await db.transaction(() async {
      await db.update(db.firms).replace(firm.copyWith(updatedAt: DateTime.now()));
      await enqueue(
        firmId: firm.id,
        entity: 'firms',
        entityId: firm.id,
        operation: 'update',
      );
    });
    return (await getById(firm.id))!;
  }

  Future<void> setDefault(String id) async {
    await db.transaction(() async {
      final allFirms = await all();
      for (final f in allFirms) {
        if (f.id != id && f.isDefault) {
          await db
              .update(db.firms)
              .replace(f.copyWith(isDefault: false, updatedAt: DateTime.now()));
        }
      }
      final target = await getById(id);
      if (target != null && !target.isDefault) {
        await db
            .update(db.firms)
            .replace(target.copyWith(isDefault: true, updatedAt: DateTime.now()));
      }
    });
  }

  /// Permanently removes [id] and every row that belongs to it.
  ///
  /// There is no recycle bin behind this: a business is not a document, and
  /// "deleted businesses" sitting indefinitely in a list is not a thing anyone
  /// wants. Settings asks for it twice — once for the scope, once by name — and
  /// the same action is what propagates an erasure request to the server.
  ///
  /// **Nothing is written to the sync outbox.** A `firms`/`delete` entry would
  /// be wrong in both modes the UI offers: "on this device only" must tell the
  /// server nothing, and "here and on the server" is an immediate authenticated
  /// call the caller makes *before* getting here. It would also be a trap — the
  /// outbox row carries this firm's id, and [eraseFirmRows] deletes exactly
  /// those rows, so the entry would erase itself.
  ///
  /// The audit row written afterwards is deliberately global (`firmId` null):
  /// the firm's own trail has just gone, and this row is the record that it
  /// did. A firm-scoped row would point at a business that no longer exists.
  Future<void> purge(String id) async {
    // Read the name first; after the delete there is nothing left to name it
    // by, and "Business 018f2a3b… was deleted" is a worse audit line than the
    // name the person recognises.
    final firm = await getById(id);

    await eraseFirmRows(db, id);

    await db.auditRepository.log(
      action: 'purge',
      entity: 'firms',
      entityId: id,
      summary: 'Business "${firm?.name ?? id}" and all its data were deleted '
          'from this device',
    );
  }

  /// The next document number for [docType], and it reserves the sequence.
  ///
  /// Runs inside a transaction: the sequence column is written with a
  /// targeted UPDATE (never a whole-row replace, which could clobber fields
  /// edited concurrently) and the UPDATE is conditioned on the sequence
  /// still being the value we read, so two concurrent mints cannot both
  /// reserve the same number — the loser retries with the fresh row.
  ///
  /// Numbers also reset each financial year: when [date]'s April-year
  /// differs from [FirmEntity.sequenceFy], every document sequence is reset
  /// to 0 before incrementing (formats embed the FY, e.g. INV-2026-27/001).
  Future<String> nextNumber(
    FirmEntity firm,
    DocSequence docType, {
    DateTime? date,
  }) async {
    final when = date ?? DateTime.now();
    final fy = when.month >= 4 ? when.year : when.year - 1;

    while (true) {
      final fresh = await db.transaction(() async {
        final current = await getById(firm.id) ?? firm;
        // The optimistic-lock guard must compare the values we READ from the
        // database — not the post-reset working copy. In the FY-reset branch
        // the working copy carries seq 0 / the new FY; guarding on those
        // never matched the stored row and nextNumber spun forever.
        final storedFy = current.sequenceFy;
        final storedSeq = _currentSequence(current, docType);
        var seq = storedSeq;
        var working = current;
        if (current.sequenceFy != fy) {
          // New financial year: restart every document sequence.
          working = working.copyWith(
            sequenceFy: Value(fy),
            invoiceSequence: 0,
            quotationSequence: 0,
            salesOrderSequence: 0,
            purchaseSequence: 0,
            paymentInSequence: 0,
            paymentOutSequence: 0,
            expenseSequence: 0,
            creditNoteSequence: 0,
            debitNoteSequence: 0,
            deliveryNoteSequence: 0,
            purchaseOrderSequence: 0,
          );
          seq = 0;
        }
        final next = seq + 1;
        final withSeq = _withSequence(working, docType, next)
            .copyWith(updatedAt: DateTime.now());

        final updated = await (db.update(db.firms)
              ..where((t) =>
                  t.id.equals(firm.id) &
                  t.sequenceFy.equalsNullable(storedFy) &
                  // Guard on the sequence we read: if another transaction
                  // already bumped it, our WHERE matches nothing.
                  _sequenceEquals(t, docType, storedSeq)))
            .write(withSeq);
        if (updated == 0) return null; // raced — retry with fresh state
        return _withSequence(working, docType, next);
      });

      if (fresh != null) {
        final style = NumberingStyle.values[fresh.numberingStyle.clamp(0, 2)];
        return DocumentNumbering.format(
          prefix: _prefixFor(fresh, docType),
          sequence: _currentSequence(fresh, docType),
          style: style,
          date: when,
          padding: fresh.invoiceSequencePadding,
        );
      }
      // Lost the race; loop and re-read. The guard makes progress certain:
      // the winner's write is committed before our next read.
    }
  }

  /// Expression matching the current sequence value for [docType]. Uses the
  /// generated `$FirmsTable` alias type so the column getters resolve.
  Expression<bool> _sequenceEquals($FirmsTable t, DocSequence docType,
          int value) =>
      switch (docType) {
        DocSequence.invoice => t.invoiceSequence.equals(value),
        DocSequence.quotation => t.quotationSequence.equals(value),
        DocSequence.salesOrder => t.salesOrderSequence.equals(value),
        DocSequence.purchase => t.purchaseSequence.equals(value),
        DocSequence.paymentIn => t.paymentInSequence.equals(value),
        DocSequence.paymentOut => t.paymentOutSequence.equals(value),
        DocSequence.expense => t.expenseSequence.equals(value),
        DocSequence.creditNote => t.creditNoteSequence.equals(value),
        DocSequence.debitNote => t.debitNoteSequence.equals(value),
        DocSequence.deliveryNote => t.deliveryNoteSequence.equals(value),
        DocSequence.purchaseOrder => t.purchaseOrderSequence.equals(value),
      };

  String _prefixFor(FirmEntity firm, DocSequence docType) {
    switch (docType) {
      case DocSequence.invoice:
        return firm.invoicePrefix;
      case DocSequence.quotation:
        return firm.quotationPrefix;
      case DocSequence.salesOrder:
        return firm.salesOrderPrefix;
      case DocSequence.purchase:
        return firm.purchasePrefix;
      case DocSequence.paymentIn:
        return firm.paymentInPrefix;
      case DocSequence.paymentOut:
        return firm.paymentOutPrefix;
      case DocSequence.expense:
        return firm.expensePrefix;
      case DocSequence.creditNote:
        return firm.creditNotePrefix;
      case DocSequence.debitNote:
        return firm.debitNotePrefix;
      case DocSequence.deliveryNote:
        return firm.deliveryNotePrefix;
      case DocSequence.purchaseOrder:
        return firm.purchaseOrderPrefix;
    }
  }

  int _currentSequence(FirmEntity firm, DocSequence docType) {
    switch (docType) {
      case DocSequence.invoice:
        return firm.invoiceSequence;
      case DocSequence.quotation:
        return firm.quotationSequence;
      case DocSequence.salesOrder:
        return firm.salesOrderSequence;
      case DocSequence.purchase:
        return firm.purchaseSequence;
      case DocSequence.paymentIn:
        return firm.paymentInSequence;
      case DocSequence.paymentOut:
        return firm.paymentOutSequence;
      case DocSequence.expense:
        return firm.expenseSequence;
      case DocSequence.creditNote:
        return firm.creditNoteSequence;
      case DocSequence.debitNote:
        return firm.debitNoteSequence;
      case DocSequence.deliveryNote:
        return firm.deliveryNoteSequence;
      case DocSequence.purchaseOrder:
        return firm.purchaseOrderSequence;
    }
  }

  FirmEntity _withSequence(FirmEntity firm, DocSequence docType, int value) {
    switch (docType) {
      case DocSequence.invoice:
        return firm.copyWith(invoiceSequence: value);
      case DocSequence.quotation:
        return firm.copyWith(quotationSequence: value);
      case DocSequence.salesOrder:
        return firm.copyWith(salesOrderSequence: value);
      case DocSequence.purchase:
        return firm.copyWith(purchaseSequence: value);
      case DocSequence.paymentIn:
        return firm.copyWith(paymentInSequence: value);
      case DocSequence.paymentOut:
        return firm.copyWith(paymentOutSequence: value);
      case DocSequence.expense:
        return firm.copyWith(expenseSequence: value);
      case DocSequence.creditNote:
        return firm.copyWith(creditNoteSequence: value);
      case DocSequence.debitNote:
        return firm.copyWith(debitNoteSequence: value);
      case DocSequence.deliveryNote:
        return firm.copyWith(deliveryNoteSequence: value);
      case DocSequence.purchaseOrder:
        return firm.copyWith(purchaseOrderSequence: value);
    }
  }

  String get _uuid => IdUtils.newId();
}

/// Deletes every row that belongs to [firmId], children before parents.
///
/// Explicit rather than leaning on `ON DELETE CASCADE`, which is the rule
/// `VyaparImportService` already follows for its rollback and for a good
/// reason: several of these tables carry a `firm_id` with **no** foreign key to
/// `firms` at all — `stock_movements`, `app_settings`, `sync_queue` and
/// `audit_logs` — so nothing would ever cascade them, and a connection opened
/// without `PRAGMA foreign_keys=ON` (the in-memory test database, for one)
/// would silently leave orphans in the rest.
///
/// This is the single place that knows what "a business's data" means. The
/// Vyapar importer's failed-import rollback and Settings' "remove this
/// business" both go through it, so a table added later cannot be erased on one
/// of those paths and forgotten on the other.
///
/// Callers are responsible for the audit trail: this removes the firm's audit
/// rows along with everything else, so anything that wants a record of the
/// deletion must write it afterwards.
Future<void> eraseFirmRows(AppDatabase db, String firmId) async {
  await db.transaction(() async {
    // Line items first. They reference their document rather than the firm, so
    // leaving them to a cascade is the one place the chain has two links.
    final invoiceIds = (await (db.select(db.salesInvoices)
              ..where((t) => t.firmId.equals(firmId)))
            .get())
        .map((row) => row.id)
        .toList();
    final billIds = (await (db.select(db.purchaseBills)
              ..where((t) => t.firmId.equals(firmId)))
            .get())
        .map((row) => row.id)
        .toList();
    // Journal lines hang off their voucher the same way an invoice line hangs
    // off its invoice — neither carries a firm id of its own.
    final journalIds = (await (db.select(db.journalEntries)
              ..where((t) => t.firmId.equals(firmId)))
            .get())
        .map((row) => row.id)
        .toList();

    if (journalIds.isNotEmpty) {
      await (db.delete(db.journalLines)
            ..where((t) => t.entryId.isIn(journalIds)))
          .go();
    }

    if (invoiceIds.isNotEmpty) {
      await (db.delete(db.salesInvoiceItems)
            ..where((t) => t.invoiceId.isIn(invoiceIds)))
          .go();
    }
    if (billIds.isNotEmpty) {
      await (db.delete(db.purchaseBillItems)
            ..where((t) => t.billId.isIn(billIds)))
          .go();
    }

    await (db.delete(db.salesInvoices)..where((t) => t.firmId.equals(firmId)))
        .go();
    await (db.delete(db.purchaseBills)..where((t) => t.firmId.equals(firmId)))
        .go();
    await (db.delete(db.payments)..where((t) => t.firmId.equals(firmId))).go();
    await (db.delete(db.expenses)..where((t) => t.firmId.equals(firmId))).go();
    await (db.delete(db.stockMovements)..where((t) => t.firmId.equals(firmId)))
        .go();
    await (db.delete(db.items)..where((t) => t.firmId.equals(firmId))).go();
    await (db.delete(db.parties)..where((t) => t.firmId.equals(firmId))).go();
    await (db.delete(db.categories)..where((t) => t.firmId.equals(firmId)))
        .go();
    await (db.delete(db.units)..where((t) => t.firmId.equals(firmId))).go();
    await (db.delete(db.firmMembers)..where((t) => t.firmId.equals(firmId)))
        .go();
    await (db.delete(db.appSettings)..where((t) => t.firmId.equals(firmId)))
        .go();
    await (db.delete(db.journalEntries)
          ..where((t) => t.firmId.equals(firmId)))
        .go();
    await (db.delete(db.accounts)..where((t) => t.firmId.equals(firmId))).go();
    await (db.delete(db.syncQueue)..where((t) => t.firmId.equals(firmId))).go();
    await (db.delete(db.auditLogs)..where((t) => t.firmId.equals(firmId))).go();
    await (db.delete(db.firms)..where((t) => t.id.equals(firmId))).go();
  });
}

/// Document series whose numbering is owned by the firm.
enum DocSequence {
  invoice,
  quotation,
  salesOrder,
  purchase,
  paymentIn,
  paymentOut,
  expense,
  creditNote,
  debitNote,
  deliveryNote,
  purchaseOrder,
}
