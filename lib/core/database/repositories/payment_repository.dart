import 'package:drift/drift.dart';

import '../app_database.dart';
import 'repository_extensions.dart';
import 'sync_mixin.dart';

/// Payments in/out against parties, optionally linked to a document.
class PaymentRepository with SyncQueueMixin {
  PaymentRepository(this.db, this.firmId);

  @override
  final AppDatabase db;

  final String firmId;

  Future<PaymentEntity> create({
    required String type, // payment_in | payment_out
    required String number,
    String? partyId,
    String? partyName,
    required double amount,
    required DateTime date,
    String mode = 'cash',
    String? reference,
    DateTime? clearanceDate,
    String? linkedInvoiceId,
    String? linkedInvoiceNumber,
    String? bankAccount,
    String? notes,
    int sequence = 0,
    // Callbacks to keep the linked document's balances in sync.
    Future<void> Function(String linkedId, double amount)? onLinked,
  }) async {
    final id = 'pay_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_${DateTime.now().microsecond}';
    await db.transaction(() async {
      await db.assertDateEditable(firmId, date);
      await db.into(db.payments).insert(PaymentsCompanion.insert(
            id: id,
            firmId: firmId,
            type: type,
            number: number,
            partyId: Value(partyId),
            partyName: Value(partyName),
            amount: amount,
            date: date,
            mode: Value(mode),
            reference: Value(reference),
            clearanceDate: Value(clearanceDate),
            linkedInvoiceId: Value(linkedInvoiceId),
            linkedInvoiceNumber: Value(linkedInvoiceNumber),
            bankAccount: Value(bankAccount),
            notes: Value(notes),
            sequence: Value(sequence),
            createdAt: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ));
      if (onLinked != null && linkedInvoiceId != null) {
        await onLinked(linkedInvoiceId, amount);
      }
      await enqueue(
        firmId: firmId,
        entity: 'payments',
        entityId: id,
        operation: 'insert',
      );
    });
    return (await getById(id))!;
  }

  Future<PaymentEntity?> getById(String id) async {
    final query = db.select(db.payments)
      ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
    return query.getSingleOrNull();
  }

  Future<List<PaymentEntity>> list({
    String? type,
    String? partyId,
    DateTime? from,
    DateTime? to,
    int limit = 500,
  }) async {
    final query = db.select(db.payments)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.date)]);
    if (type != null) {
      query.where((t) => t.type.equals(type));
    }
    if (partyId != null) {
      query.where((t) => t.partyId.equals(partyId));
    }
    if (from != null) {
      query.where((t) => t.date.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query.where((t) => t.date.isSmallerOrEqualValue(to));
    }
    query.limit(limit);
    return query.get();
  }

  Stream<List<PaymentEntity>> watchList({
    String? type,
    DateTime? from,
    DateTime? to,
    int limit = 100,
  }) {
    final query = db.select(db.payments)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.date)]);
    if (type != null) {
      query.where((t) => t.type.equals(type));
    }
    if (from != null) {
      query.where((t) => t.date.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query.where((t) => t.date.isSmallerOrEqualValue(to));
    }
    query.limit(limit);
    return query.watch();
  }

  /// Party ledger: all payments for a party, newest first.
  Future<List<PaymentEntity>> forParty(String partyId,
      {int limit = 1000}) async {
    final query = db.select(db.payments)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.partyId.equals(partyId) &
          t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.date)])
      ..limit(limit);
    return query.get();
  }

  Future<double> totalForType(String type,
      {DateTime? from, DateTime? to}) async {
    final rows = await list(type: type, from: from, to: to, limit: 1000000);
    var total = 0.0;
    for (final r in rows) {
      total += r.amount;
    }
    return total;
  }

  /// Soft-deletes into the document recycle bin. If the payment settles a
  /// linked document, that document's paid/balance/status columns are
  /// recomputed (the payment must stop counting the moment it is binned) —
  /// and again on restore.
  Future<void> softDelete(String id, {String? actor}) async {
    await db.transaction(() async {
      final query = db.select(db.payments)
        ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
      final payment = await query.getSingleOrNull();
      if (payment == null) return;
      await db.assertDateEditable(firmId, payment.date);
      await (db.update(db.payments)..where((t) => t.id.equals(id))).write(
        PaymentsCompanion(
          isDeleted: const Value(true),
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      // A deleted payment must stop settling its linked document at once,
      // or the invoice keeps showing Paid with a bin holding its payment.
      await _recomputeLinkedDoc(payment);
      await enqueue(
          firmId: firmId, entity: 'payments', entityId: id, operation: 'delete');
      await db.auditRepository.log(
        action: 'delete',
        entity: 'payments',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Deleted ${payment.type} ${payment.number} '
            '(${payment.partyName ?? "no party"})',
      );
    });
  }

  /// Restores a soft-deleted payment and re-applies its effect on the
  /// linked document's balances.
  Future<void> restore(String id, {String? actor}) async {
    await db.transaction(() async {
      final query = db.select(db.payments)
        ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
      final payment = await query.getSingleOrNull();
      if (payment == null) return;
      await db.assertDateEditable(firmId, payment.date);
      await (db.update(db.payments)..where((t) => t.id.equals(id))).write(
        PaymentsCompanion(
          isDeleted: const Value(false),
          deletedAt: const Value(null),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await _recomputeLinkedDoc(payment);
      await enqueue(
          firmId: firmId, entity: 'payments', entityId: id, operation: 'update');
      await db.auditRepository.log(
        action: 'restore',
        entity: 'payments',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Restored ${payment.type} ${payment.number}',
      );
    });
  }

  /// Recomputes the linked sales invoice's (or purchase bill's) paidAmount /
  /// balanceDue / paymentStatus from every live payment referencing it.
  ///
  /// This is the single source of truth for "what does a linked payment do to
  /// its document": applyPayment bumps the counters, delete/restore derive
  /// them back from the payments table.
  Future<void> _recomputeLinkedDoc(PaymentEntity payment) async {
    final linkId = payment.linkedInvoiceId;
    if (linkId == null || linkId.isEmpty) return;

    // Only payments that still count (not binned) feed the totals.
    final live = await (db.select(db.payments)
          ..where((t) =>
              t.firmId.equals(firmId) &
              t.linkedInvoiceId.equals(linkId) &
              t.isDeleted.equals(false)))
        .get();
    var paid = 0.0;
    for (final p in live) {
      paid += p.type == 'payment_in' ? p.amount : -p.amount;
    }
    paid = paid < 0 ? 0 : paid;

    final invoice = await (db.select(db.salesInvoices)
          ..where((t) => t.id.equals(linkId) & t.firmId.equals(firmId)))
        .getSingleOrNull();
    if (invoice != null) {
      final balance = invoice.grandTotal - paid;
      final status =
          balance <= 0.001 ? 'paid' : (paid > 0.001 ? 'partial' : 'unpaid');
      await (db.update(db.salesInvoices)..where((t) => t.id.equals(linkId)))
          .write(SalesInvoicesCompanion(
        paidAmount: Value(paid),
        balanceDue: Value(balance < 0 ? 0 : balance),
        paymentStatus: Value(status),
        updatedAt: Value(DateTime.now()),
      ));
      return;
    }

    final bill = await (db.select(db.purchaseBills)
          ..where((t) => t.id.equals(linkId) & t.firmId.equals(firmId)))
        .getSingleOrNull();
    if (bill != null) {
      final balance = bill.grandTotal - paid;
      final status =
          balance <= 0.001 ? 'paid' : (paid > 0.001 ? 'partial' : 'unpaid');
      await (db.update(db.purchaseBills)..where((t) => t.id.equals(linkId)))
          .write(PurchaseBillsCompanion(
        paidAmount: Value(paid),
        balanceDue: Value(balance < 0 ? 0 : balance),
        paymentStatus: Value(status),
        updatedAt: Value(DateTime.now()),
      ));
    }
  }

  /// Rows in the document recycle bin, newest deletion first.
  Stream<List<PaymentEntity>> watchDeleted() {
    final query = db.select(db.payments)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(true))
      ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]);
    return query.watch();
  }

  /// Hard-deletes a recycled payment.
  Future<void> deleteForever(String id) async {
    await db.transaction(() async {
      final query = db.select(db.payments)
        ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
      final payment = await query.getSingleOrNull();
      if (payment == null) return;
      if (!payment.isDeleted) {
        throw StateError(
            'Move this payment to the recycle bin before deleting it '
            'permanently.');
      }
      await db.assertDateEditable(firmId, payment.date);
      await (db.delete(db.payments)
            ..where((t) => t.id.equals(id) & t.firmId.equals(firmId)))
          .go();
      await db.auditRepository.log(
        action: 'purge',
        entity: 'payments',
        firmId: firmId,
        entityId: id,
        summary: 'Permanently deleted payment '
            '${payment.number} (${payment.partyName ?? "no party"})',
      );
    });
  }
}

/// Business expenses and other income.
class ExpenseRepository with SyncQueueMixin {
  ExpenseRepository(this.db, this.firmId);

  @override
  final AppDatabase db;

  final String firmId;

  Future<ExpenseEntity> create({
    required String type, // expense | income
    required String number,
    required String category,
    required double amount,
    required DateTime date,
    String mode = 'cash',
    String? vendorName,
    String? reference,
    double gstAmount = 0,
    String? notes,
    int sequence = 0,
  }) async {
    final id = 'exp_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_${DateTime.now().microsecond}';
    await db.transaction(() async {
      await db.assertDateEditable(firmId, date);
      await db.into(db.expenses).insert(ExpensesCompanion.insert(
            id: id,
            firmId: firmId,
            type: Value(type),
            number: number,
            category: category,
            amount: amount,
            date: date,
            mode: Value(mode),
            vendorName: Value(vendorName),
            reference: Value(reference),
            gstAmount: Value(gstAmount),
            notes: Value(notes),
            sequence: Value(sequence),
            createdAt: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ));
      await enqueue(
        firmId: firmId,
        entity: 'expenses',
        entityId: id,
        operation: 'insert',
      );
    });
    return (await getById(id))!;
  }

  Future<ExpenseEntity?> getById(String id) async {
    final query = db.select(db.expenses)
      ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
    return query.getSingleOrNull();
  }

  Future<List<ExpenseEntity>> list({
    String type = 'expense',
    String? category,
    DateTime? from,
    DateTime? to,
    int limit = 500,
  }) async {
    final query = db.select(db.expenses)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.type.equals(type) &
          t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.date)]);
    if (category != null) {
      query.where((t) => t.category.equals(category));
    }
    if (from != null) {
      query.where((t) => t.date.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query.where((t) => t.date.isSmallerOrEqualValue(to));
    }
    query.limit(limit);
    return query.get();
  }

  Stream<List<ExpenseEntity>> watchList({
    String type = 'expense',
    DateTime? from,
    DateTime? to,
    int limit = 100,
  }) {
    final query = db.select(db.expenses)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.type.equals(type) &
          t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.date)]);
    if (from != null) {
      query.where((t) => t.date.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query.where((t) => t.date.isSmallerOrEqualValue(to));
    }
    query.limit(limit);
    return query.watch();
  }

  Future<double> totalForType(String type,
      {DateTime? from, DateTime? to}) async {
    final rows = await list(type: type, from: from, to: to, limit: 1000000);
    var total = 0.0;
    for (final r in rows) {
      total += r.amount;
    }
    return total;
  }

  /// Total expenses grouped by category, for the P&L and dashboards.
  Future<Map<String, double>> totalsByCategory({
    String type = 'expense',
    DateTime? from,
    DateTime? to,
  }) async {
    final rows = await list(type: type, from: from, to: to, limit: 1000000);
    final totals = <String, double>{};
    for (final r in rows) {
      totals[r.category] = (totals[r.category] ?? 0) + r.amount;
    }
    return totals;
  }

  /// Persists edits to an existing expense/income row. Nullable columns are
  /// taken from the entity as-is, so the caller decides via `copyWith(Value(...))`
  /// whether clearing a field writes NULL.
  Future<ExpenseEntity> update(ExpenseEntity expense) async {
    await db.transaction(() async {
      await db.assertDateEditable(firmId, expense.date);
      await db
          .update(db.expenses)
          .replace(expense.copyWith(updatedAt: DateTime.now()));
      await enqueue(
        firmId: firmId,
        entity: 'expenses',
        entityId: expense.id,
        operation: 'update',
      );
    });
    return (await getById(expense.id))!;
  }

  /// Soft-deletes into the document recycle bin (audited, lock-aware).
  Future<void> softDelete(String id, {String? actor}) async {
    await db.transaction(() async {
      final query = db.select(db.expenses)
        ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
      final expense = await query.getSingleOrNull();
      if (expense == null) return;
      await db.assertDateEditable(firmId, expense.date);
      await (db.update(db.expenses)..where((t) => t.id.equals(id))).write(
        ExpensesCompanion(
          isDeleted: const Value(true),
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await enqueue(
          firmId: firmId, entity: 'expenses', entityId: id, operation: 'delete');
      await db.auditRepository.log(
        action: 'delete',
        entity: 'expenses',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Deleted ${expense.type} ${expense.number} '
            '(${expense.category})',
      );
    });
  }

  /// Hard-deletes a recycled expense (must already be soft-deleted).
  Future<void> deleteForever(String id) async {
    await db.transaction(() async {
      final query = db.select(db.expenses)
        ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
      final expense = await query.getSingleOrNull();
      if (expense == null) return;
      if (!expense.isDeleted) {
        throw StateError(
            'Move this expense to the recycle bin before deleting it '
            'permanently.');
      }
      await db.assertDateEditable(firmId, expense.date);
      await (db.delete(db.expenses)
            ..where((t) => t.id.equals(id) & t.firmId.equals(firmId)))
          .go();
      await db.auditRepository.log(
        action: 'purge',
        entity: 'expenses',
        firmId: firmId,
        entityId: id,
        summary: 'Permanently deleted expense '
            '${expense.number} (${expense.category})',
      );
    });
  }

  /// Restores a soft-deleted expense/income row.
  Future<void> restore(String id, {String? actor}) async {
    await db.transaction(() async {
      final query = db.select(db.expenses)
        ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
      final expense = await query.getSingleOrNull();
      if (expense == null) return;
      await db.assertDateEditable(firmId, expense.date);
      await (db.update(db.expenses)..where((t) => t.id.equals(id))).write(
        ExpensesCompanion(
          isDeleted: const Value(false),
          deletedAt: const Value(null),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await enqueue(
          firmId: firmId, entity: 'expenses', entityId: id, operation: 'update');
      await db.auditRepository.log(
        action: 'restore',
        entity: 'expenses',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Restored ${expense.type} ${expense.number}',
      );
    });
  }

  /// Rows in the document recycle bin, newest deletion first.
  Stream<List<ExpenseEntity>> watchDeleted() {
    final query = db.select(db.expenses)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(true))
      ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]);
    return query.watch();
  }
}
