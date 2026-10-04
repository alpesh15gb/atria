import 'package:drift/drift.dart';

import '../../utils/id_utils.dart';
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
    final id = 'pay_${IdUtils.newId()}';
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
            // A cheque starts its life in hand. Recorded here rather than left
            // to the caller so every path that records a cheque — the payments
            // screen, a POS settlement, an import — produces the same starting
            // state, and the deposit/clear/bounce actions have something to act
            // on.
            chequeStatus: Value(mode == 'cheque' ? 'pending' : null),
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

  /// Persists edits to a payment — every field except its number. A payment
  /// that settles a document feeds that document's paid/balance columns both
  /// before and after the change, so both links (an edit can re-point the
  /// link) are recomputed from the live rows.
  Future<void> update(PaymentEntity payment, {String? actor}) async {
    await db.transaction(() async {
      await db.assertDateEditable(firmId, payment.date);
      final original = await getById(payment.id);

      // Invariant: `chequeStatus` describes a CHEQUE and nothing else.
      //
      // A payment is either in the cheque lifecycle (in hand → given to the
      // bank → cleared or returned) or it is not, and every reader depends on
      // that: [watchUnclearedCheques] filters on the status, the ledger posts a
      // cheque to Cheques-in-hand only while the mode is cheque and the status
      // is not `cleared`, and [_recomputeLinkedDoc] stops a *bounced* cheque
      // settling its document. Writing the existing status regardless of the
      // new mode broke that in both directions. cheque→cash kept a `pending`
      // that counted in "Cheques to deposit" AND as cash, and the row could
      // no longer reach a cheque menu (the menu is gated on
      // `mode == 'cheque'`), so it was stuck in a bucket nothing could move.
      // cash→cheque left the status null, so the new cheque never entered
      // [watchUnclearedCheques] at all and had no deposit/clear/bounce to act
      // on. A fresh cheque is seeded `pending` here for the same reason
      // [create] does it — one starting state, whichever path records the
      // cheque.
      //
      // Only a *changed* mode touches the lifecycle columns: editing the
      // amount, date, reference or notes of a cheque must leave it exactly
      // where the bank had got to with it.
      final startingCheque =
          payment.mode == 'cheque' && original?.mode != 'cheque';
      final leavingCheque = payment.mode != 'cheque';
      final resetChequeState = startingCheque || leavingCheque;
      final chequeStatus = leavingCheque
          ? null
          : startingCheque
          ? 'pending'
          : payment.chequeStatus;

      await (db.update(db.payments)
            ..where(
                (t) => t.id.equals(payment.id) & t.firmId.equals(firmId)))
          .write(PaymentsCompanion(
        type: Value(payment.type),
        partyId: Value(payment.partyId),
        partyName: Value(payment.partyName),
        amount: Value(payment.amount),
        date: Value(payment.date),
        mode: Value(payment.mode),
        reference: Value(payment.reference),
        // The lifecycle columns move together with `chequeStatus`: a cheque
        // that becomes cash carries no deposit stamp, no bounce reason, and a
        // cash payment turned cheque carries none of them either.
        clearanceDate: Value(resetChequeState ? null : payment.clearanceDate),
        chequeStatus: Value(chequeStatus),
        depositedAt: Value(resetChequeState ? null : payment.depositedAt),
        bouncedAt: Value(resetChequeState ? null : payment.bouncedAt),
        bounceReason: Value(resetChequeState ? null : payment.bounceReason),
        linkedInvoiceId: Value(payment.linkedInvoiceId),
        linkedInvoiceNumber: Value(payment.linkedInvoiceNumber),
        bankAccount: Value(payment.bankAccount),
        notes: Value(payment.notes),
        updatedAt: Value(DateTime.now()),
      ));
      await enqueue(
        firmId: firmId,
        entity: 'payments',
        entityId: payment.id,
        operation: 'update',
      );
      // The old link may differ from the new one — both documents'
      // balances must be derived again.
      if (original != null) {
        await _recomputeLinkedDoc(original);
      }
      await _recomputeLinkedDoc(payment);
      await db.auditRepository.log(
        action: 'update',
        entity: 'payments',
        firmId: firmId,
        actor: actor,
        entityId: payment.id,
        summary: 'Edited ${payment.type} ${payment.number} '
            '(${payment.partyName ?? "no party"})',
      );
    });
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
    final invoice = await (db.select(db.salesInvoices)
          ..where((t) => t.id.equals(linkId) & t.firmId.equals(firmId)))
        .getSingleOrNull();
    var paid = 0.0;
    // How a linked payment moves the document's balance depends on which
    // side of the books the document sits on: a payment_in is a receipt
    // against a sales invoice, a payment_out settles a purchase bill.
    // Signing every linked bill as +in/−out drove a bill's paid amount
    // NEGATIVE the moment any of its payment_out rows was binned or
    // restored, flipping it back to Unpaid.
    final isReceipt = invoice != null;
    for (final p in live) {
      // A cheque the bank returned unpaid is money that never arrived, so it
      // must stop settling the document the moment it bounces — otherwise the
      // invoice stays marked Paid against a payment that was reversed, which
      // is how a shop ends up chasing a customer it believes has paid.
      // A cheque merely *in hand* still counts: that is the optimistic reading
      // every Indian billing app uses, and the bounce is the correction.
      if (p.chequeStatus == 'bounced') continue;
      final positive = isReceipt
          ? p.type == 'payment_in'
          : p.type == 'payment_out';
      paid += positive ? p.amount : -p.amount;
    }
    paid = paid < 0 ? 0 : paid;
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

  // ---- Cheque lifecycle ---------------------------------------------------

  /// The cheques whose money has not arrived yet, newest first.
  ///
  /// "Not arrived" means pending (in hand, not yet given to the bank) or
  /// deposited (given to the bank, not yet cleared). This is the list the
  /// operator works through: deposit the ones in hand, then mark the ones the
  /// bank has cleared.
  Stream<List<PaymentEntity>> watchUnclearedCheques() {
    final query = db.select(db.payments)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.isDeleted.equals(false) &
          t.chequeStatus.isIn(const ['pending', 'deposited']))
      ..orderBy([(t) => OrderingTerm.asc(t.date)]);
    return query.watch();
  }

  /// Cheques the bank returned unpaid.
  Stream<List<PaymentEntity>> watchBouncedCheques() {
    final query = db.select(db.payments)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.isDeleted.equals(false) &
          t.chequeStatus.equals('bounced'))
      ..orderBy([(t) => OrderingTerm.desc(t.date)]);
    return query.watch();
  }

  /// Records that a cheque was handed to the bank.
  ///
  /// Depositing does not move the money: the bank can still return it, and a
  /// balance that counted it the moment it was handed over would be wrong for
  /// as long as the clearing takes.
  Future<void> markChequeDeposited(String id, {DateTime? date}) async {
    await _setChequeState(
      id,
      status: 'deposited',
      actor: null,
      apply: (when) => PaymentsCompanion(
        chequeStatus: const Value('deposited'),
        depositedAt: Value(when),
        // A re-deposit of a returned cheque clears the bounce: the reason it
        // bounced was dealt with, and leaving it on the row would keep the
        // reversal in the books for ever.
        bouncedAt: const Value(null),
        bounceReason: const Value(null),
        updatedAt: Value(DateTime.now()),
      ),
      when: date,
      summary: 'Cheque deposited',
    );
  }

  /// Records that the bank cleared a cheque — the money has arrived.
  Future<void> markChequeCleared(String id, {DateTime? date}) async {
    await _setChequeState(
      id,
      status: 'cleared',
      actor: null,
      apply: (when) => PaymentsCompanion(
        chequeStatus: const Value('cleared'),
        clearanceDate: Value(when),
        bouncedAt: const Value(null),
        bounceReason: const Value(null),
        updatedAt: Value(DateTime.now()),
      ),
      when: date,
      summary: 'Cheque cleared',
    );
  }

  /// Records that the bank returned a cheque unpaid.
  ///
  /// This is the one cheque action that changes the books: the document the
  /// payment was settling becomes unpaid again (see [_recomputeLinkedDoc]),
  /// because the money was never received. The reason is kept because it is
  /// what the follow-up call to the customer is about.
  Future<void> markChequeBounced(
    String id, {
    required String reason,
    DateTime? date,
  }) async {
    await _setChequeState(
      id,
      status: 'bounced',
      actor: null,
      apply: (when) => PaymentsCompanion(
        chequeStatus: const Value('bounced'),
        bouncedAt: Value(when),
        bounceReason: Value(reason.trim().isEmpty ? null : reason.trim()),
        updatedAt: Value(DateTime.now()),
      ),
      when: date,
      summary: 'Cheque bounced: ${reason.trim().isEmpty ? 'no reason given' : reason.trim()}',
    );
  }

  /// The states a cheque can be moved *into*, keyed by the state it is in.
  ///
  /// WHY a table: the three actions are a lifecycle, not three independent
  /// buttons, and every one of them changes the books except the deposit. Read
  /// as independent buttons, each of these is a silent money bug — the second
  /// tap reports success and corrupts the ledger:
  ///
  /// - `cleared → bounced` reverses a document whose money has already been
  ///   spent out of the till, and takes a live "Cheques in hand" asset back off
  ///   the balance sheet. A cheque that comes back after clearing is a bank
  ///   error the operator handles by editing the payment, not a bounce.
  /// - `bounced → cleared` books money that never arrived — it also wipes the
  ///   bounce reason, so the correction looks like it was never made.
  /// - `cleared → deposited` puts a settled cheque back in the uncleared
  ///   bucket, where it will sit being chased.
  /// - `bounced → bounced` re-asks for the reason and overwrites the first one
  ///   for no gain.
  ///
  /// Re-doing the state the cheque is already in stays legal (each target
  /// includes itself): a till is a place where people double-tap, and those
  /// repeats are no-ops rather than reversals.
  static const Map<String, Set<String>> _legalChequeTransitions = {
    'pending': {'pending', 'deposited', 'cleared', 'bounced'},
    'deposited': {'deposited', 'cleared', 'bounced'},
    'cleared': {'cleared'},
    'bounced': {'deposited'},
  };

  /// The transitions legal from [currentStatus], as the states to move into.
  ///
  /// Exposed so a caller can decide what to *offer*. The repository is still
  /// the authority — [markChequeDeposited] and friends re-check — but a menu
  /// that can reach an entry the repository will refuse is a menu that trains
  /// the operator to expect an error. A `null` status on a cheque (a row
  /// written before [create] seeded one) is treated as `pending`, which is what
  /// the "in hand" bucket already assumes.
  static Set<String> legalChequeTransitionsFrom(String? currentStatus) =>
      _legalChequeTransitions[currentStatus ?? 'pending'] ??
      const <String>{};

  /// The message shown when a move is refused, saying what the cheque actually
  /// is and what to do instead. Verbatim text, because it is shown to the user.
  static String _illegalChequeMove(String from, String to) =>
      switch ('$from>$to') {
        'cleared>bounced' =>
          'This cheque has already cleared, so its money is in the bank. '
              'If the bank has actually reversed it, edit the payment instead '
              'of marking it bounced.',
        'cleared>deposited' =>
          'This cheque has already cleared. It no longer needs depositing.',
        'bounced>cleared' =>
          'This cheque was returned by the bank. Record it as deposited again '
              'once it is re-presented — clearing it here would book money that '
              'never arrived.',
        'bounced>bounced' => 'This cheque is already marked bounced.',
        _ => 'A cheque that is $from cannot be marked $to.',
      };

  /// The shared body of the three transitions above.
  ///
  /// [status] is the state being moved *into*, and exists for the guard rather
  /// than for the write. The guard used to be nothing but `mode != 'cheque'`,
  /// which left a settled cheque reversible by a second tap; it is now the
  /// lifecycle table above, so an illegal move throws a [StateError] carrying
  /// a sentence the caller can show verbatim.
  Future<void> _setChequeState(
    String id, {
    required String status,
    required String? actor,
    required PaymentsCompanion Function(DateTime when) apply,
    required DateTime? when,
    required String summary,
  }) async {
    await db.transaction(() async {
      final query = db.select(db.payments)
        ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
      final payment = await query.getSingleOrNull();
      if (payment == null) return;
      if (payment.mode != 'cheque') {
        throw StateError(
            'Only a cheque has a deposit, clearance or bounce to record.');
      }
      final from = payment.chequeStatus ?? 'pending';
      if (!legalChequeTransitionsFrom(from).contains(status)) {
        throw StateError(_illegalChequeMove(from, status));
      }
      await db.assertDateEditable(firmId, when ?? payment.date);

      final at = when ?? DateTime.now();
      await (db.update(db.payments)
            ..where((t) => t.id.equals(id) & t.firmId.equals(firmId)))
          .write(apply(at));
      await enqueue(
        firmId: firmId,
        entity: 'payments',
        entityId: id,
        operation: 'update',
      );
      // Recomputed whatever the new state is: a bounce releases the document,
      // and a clear (or a re-deposit after a bounce) puts it back.
      await _recomputeLinkedDoc(payment.copyWith(
        chequeStatus: Value(status),
        clearanceDate:
            Value(status == 'cleared' ? at : payment.clearanceDate),
      ));
      await db.auditRepository.log(
        action: 'update',
        entity: 'payments',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: '$summary — ${payment.type} ${payment.number} '
            '(${payment.partyName ?? "no party"})',
      );
    });
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
    final id = 'exp_${IdUtils.newId()}';
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
