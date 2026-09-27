import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../../engine/gst_engine.dart';
import '../../utils/money.dart';
import '../app_database.dart';
import 'repository_extensions.dart';
import 'sales_repository.dart';
import 'sync_mixin.dart';

class PurchaseLineDraft {
  final String id;
  final String? itemId;
  final String name;
  final String? hsn;
  final Decimal quantity;
  final String unit;
  final Decimal rate;
  final Decimal? discountPercent;
  final double gstRate;
  final double cessRate;
  final TaxMode taxMode;

  const PurchaseLineDraft({
    required this.id,
    this.itemId,
    required this.name,
    this.hsn,
    required this.quantity,
    required this.unit,
    required this.rate,
    this.discountPercent,
    required this.gstRate,
    this.cessRate = 0,
    this.taxMode = TaxMode.exclusive,
  });

  TaxLine toTaxLine() => TaxLine(
        id: id,
        itemId: itemId,
        name: name,
        hsn: hsn,
        quantity: quantity,
        unit: unit,
        rate: rate,
        discountPercent: discountPercent ?? Money.zero,
        gstRate: gstRate,
        cessRate: cessRate,
        taxMode: taxMode,
      );

  /// Writes the resolved per-line tax figures. These columns back the bill's
  /// line table and its PDF, so leaving them out renders every saved line as
  /// ₹0.00 taxable / ₹0.00 total.
  PurchaseBillItemsCompanion toCompanion(
      String billId, int order, ComputedLine? computed) {
    return PurchaseBillItemsCompanion.insert(
      id: id,
      billId: billId,
      itemId: Value(itemId),
      name: name,
      hsn: Value(hsn),
      quantity: quantity.toDouble(),
      unit: Value(unit),
      rate: rate.toDouble(),
      discountPercent: Value((discountPercent ?? Money.zero).toDouble()),
      gstRate: Value(gstRate),
      cessRate: Value(cessRate),
      taxMode: Value(taxMode == TaxMode.inclusive ? 'inclusive' : 'exclusive'),
      taxableValue: Value(computed?.taxableValue.toDouble() ?? 0),
      cgst: Value(computed?.cgst.toDouble() ?? 0),
      sgst: Value(computed?.sgst.toDouble() ?? 0),
      igst: Value(computed?.igst.toDouble() ?? 0),
      cessAmount: Value(computed?.cess.toDouble() ?? 0),
      total: Value(computed?.total.toDouble() ?? 0),
      sortOrder: Value(order),
    );
  }
}

class PurchaseDraft {
  final String id;
  final String number;
  final String docType; // bill | purchase_order | debit_note
  final String? partyId;
  final String? supplierInvoiceNumber;
  final DateTime billDate;
  final DateTime? dueDate;
  final String status;
  final List<PurchaseLineDraft> lines;
  final String? partyName;
  final String? partyGstin;
  final String? partyGstType;
  final String? partyPhone;
  final String? billingAddress;
  final String? placeOfSupply;
  final bool isInterState;
  final bool reverseCharge;
  final Decimal? invoiceDiscountPercent;
  final Decimal? invoiceDiscountAmount;
  final Decimal? shippingCharge;
  final Decimal? otherCharges;

  /// Resolved values. `Money.zero` isn't a compile-time constant, so the fields
  /// are nullable and default to zero here for readers that need a [Decimal].
  Decimal get invoiceDiscountPercentValue =>
      invoiceDiscountPercent ?? Money.zero;
  Decimal get invoiceDiscountAmountValue =>
      invoiceDiscountAmount ?? Money.zero;
  Decimal get shippingChargeValue => shippingCharge ?? Money.zero;
  Decimal get otherChargesValue => otherCharges ?? Money.zero;
  final bool applyRoundOff;
  final String? notes;
  final int sequence;

  const PurchaseDraft({
    required this.id,
    required this.number,
    required this.docType,
    this.partyId,
    this.supplierInvoiceNumber,
    required this.billDate,
    this.dueDate,
    this.status = 'confirmed',
    required this.lines,
    this.partyName,
    this.partyGstin,
    this.partyGstType,
    this.partyPhone,
    this.billingAddress,
    this.placeOfSupply,
    this.isInterState = false,
    this.reverseCharge = false,
    this.invoiceDiscountPercent,
    this.invoiceDiscountAmount,
    this.shippingCharge,
    this.otherCharges,
    this.applyRoundOff = true,
    this.notes,
    this.sequence = 0,
  });
}

class PurchaseRepository with SyncQueueMixin {
  PurchaseRepository(this.db, this.firmId);

  @override
  final AppDatabase db;

  final String firmId;

  Future<PurchaseBillEntity> save(PurchaseDraft draft,
      {bool affectStock = true, String? createdBy}) async {
    final split = draft.isInterState ? GstSplit.interState : GstSplit.intraState;
    final result = GstEngine.computeDocument(
      lines: draft.lines.map((l) => l.toTaxLine()).toList(),
      split: split,
      invoiceDiscountPercent: draft.invoiceDiscountPercentValue,
      invoiceDiscountAmount: draft.invoiceDiscountAmountValue,
      applyRoundOff: draft.applyRoundOff,
    );
    final grandTotal =
        result.grandTotal +
            draft.shippingChargeValue +
            draft.otherChargesValue;
    final now = DateTime.now();

    await db.transaction(() async {
      // An edit reuses the bill id. The old code ran the same INSERT as a new
      // bill, so editing a bill either threw on the duplicate id or, once it
      // got past that, reset paidAmount to 0 (forgetting recorded payments),
      // left the stale line rows behind and posted the stock-in twice.
      final existing = await getById(draft.id);
      final isEdit = existing != null;
      final createdAt = existing?.createdAt ?? now;

      // Period lock: same rule as sales (see sales_repository.save).
      await db.assertDateEditable(firmId, draft.billDate);
      if (isEdit) {
        await db.assertDateEditable(firmId, existing.billDate);
      }

      if (isEdit) {
        await db.reverseStockForSource(firmId, draft.id);
        await (db.delete(db.purchaseBillItems)
              ..where((t) => t.billId.equals(draft.id)))
            .go();
      }

      final paidAmount = existing?.paidAmount ?? 0.0;
      final balance = grandTotal.toDouble() - paidAmount;
      final paymentStatus = balance <= 0.001
          ? 'paid'
          : (paidAmount > 0.001 ? 'partial' : 'unpaid');

      final companion = PurchaseBillsCompanion.insert(
        id: draft.id,
        firmId: firmId,
        docType: Value(draft.docType),
        number: draft.number,
        supplierInvoiceNumber: Value(draft.supplierInvoiceNumber),
        partyId: Value(draft.partyId),
        billDate: draft.billDate,
        dueDate: Value(draft.dueDate),
        status: Value(draft.status),
        paymentStatus: Value(paymentStatus),
        paidAmount: Value(paidAmount),
        balanceDue: Value(draft.docType == 'bill' ? balance : 0),
        partyName: Value(draft.partyName),
        partyGstin: Value(draft.partyGstin),
        partyGstType: Value(draft.partyGstType),
        partyPhone: Value(draft.partyPhone),
        billingAddress: Value(draft.billingAddress),
        placeOfSupply: Value(draft.placeOfSupply),
        isInterState: Value(draft.isInterState),
        reverseCharge: Value(draft.reverseCharge),
        subTotal: Value(result.subTotal.toDouble()),
        itemDiscount: Value(result.itemDiscountTotal.toDouble()),
        invoiceDiscountPercent:
            Value(draft.invoiceDiscountPercentValue.toDouble()),
        invoiceDiscountAmount:
            Value(draft.invoiceDiscountAmountValue.toDouble()),
        shippingCharge: Value(draft.shippingChargeValue.toDouble()),
        otherCharges: Value(draft.otherChargesValue.toDouble()),
        taxableValue: Value(result.taxableValue.toDouble()),
        cgst: Value(result.cgstTotal.toDouble()),
        sgst: Value(result.sgstTotal.toDouble()),
        igst: Value(result.igstTotal.toDouble()),
        cess: Value(result.cessTotal.toDouble()),
        roundOff: Value(result.roundOff.toDouble()),
        grandTotal: Value(grandTotal.toDouble()),
        notes: Value(draft.notes),
        createdBy: Value(createdBy),
        createdAt: Value(createdAt),
        updatedAt: Value(now),
        sequence: Value(draft.sequence),
      );

      if (isEdit) {
        await db.into(db.purchaseBills).insertOnConflictUpdate(companion);
      } else {
        await db.into(db.purchaseBills).insert(companion);
      }

      for (var i = 0; i < draft.lines.length; i++) {
        await db.into(db.purchaseBillItems).insert(draft.lines[i]
            .toCompanion(draft.id, i, result.lineFor(draft.lines[i].id)));
      }

      if (affectStock && draft.docType != 'purchase_order') {
        for (final line in draft.lines) {
          if (line.itemId == null || line.quantity == Money.zero) continue;
          final sign = draft.docType == 'debit_note' ? -1.0 : 1.0;
          await db.stockMovementsInsert(
            firmId,
            line.itemId!,
            sign * line.quantity.toDouble(),
            draft.docType == 'debit_note' ? 'purchase_return' : 'purchase',
            'purchase_bills',
            draft.id,
            draft.number,
            draft.billDate,
          );
        }
      }

      await enqueue(
        firmId: firmId,
        entity: 'purchase_bills',
        entityId: draft.id,
        operation: isEdit ? 'update' : 'insert',
      );
    });

    return (await getById(draft.id))!;
  }

  Future<PurchaseBillEntity?> getById(String id) async {
    final query = db.select(db.purchaseBills)
      ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
    return query.getSingleOrNull();
  }

  /// Soft-deletes into the document recycle bin (stock-in reversed, audit
  /// written, locked periods respected). See sales_repository.softDelete.
  Future<void> softDelete(String id, {String? actor}) async {
    await db.transaction(() async {
      final bill = await getById(id);
      if (bill == null) return;
      await db.assertDateEditable(firmId, bill.billDate);
      await db.reverseStockForSource(firmId, id);
      await (db.update(db.purchaseBills)..where((t) => t.id.equals(id))).write(
        PurchaseBillsCompanion(
          isDeleted: const Value(true),
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await enqueue(
          firmId: firmId, entity: 'purchase_bills', entityId: id,
          operation: 'delete');
      await db.auditRepository.log(
        action: 'delete',
        entity: 'purchase_bills',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Deleted ${bill.docType} ${bill.number}'
            ' for ${bill.partyName ?? "supplier"}',
      );
    });
  }

  /// Restores a soft-deleted bill and re-applies its stock effect. Bills
  /// add stock back in, debit notes (purchase returns) deduct it again —
  /// matching the sign each doc type posts on save, so delete+restore is
  /// net zero on the stock ledger.
  Future<void> restore(String id, {String? actor}) async {
    await db.transaction(() async {
      final bill = await getById(id);
      if (bill == null) return;
      await db.assertDateEditable(firmId, bill.billDate);
      await (db.update(db.purchaseBills)..where((t) => t.id.equals(id))).write(
        PurchaseBillsCompanion(
          isDeleted: const Value(false),
          deletedAt: const Value(null),
          updatedAt: Value(DateTime.now()),
        ),
      );
      if (bill.docType != 'purchase_order' && bill.status != 'cancelled') {
        final sign = bill.docType == 'debit_note' ? -1.0 : 1.0;
        final kind =
            bill.docType == 'debit_note' ? 'purchase_return' : 'purchase';
        final items = await itemsFor(id);
        final itemRepo = db.itemRepositoryFor(firmId);
        for (final l in items) {
          if (l.itemId != null) {
            await itemRepo.applyStockEffect(
              itemId: l.itemId!,
              quantity: sign * l.quantity,
              kind: kind,
              source: 'purchase_bills',
              sourceId: id,
              sourceNumber: bill.number,
              date: bill.billDate,
            );
          }
        }
      }
      await enqueue(
          firmId: firmId, entity: 'purchase_bills', entityId: id,
          operation: 'update');
      await db.auditRepository.log(
        action: 'restore',
        entity: 'purchase_bills',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Restored ${bill.docType} ${bill.number}',
      );
    });
  }

  /// Rows in the document recycle bin, newest deletion first.
  Stream<List<PurchaseBillEntity>> watchDeleted() {
    final query = db.select(db.purchaseBills)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(true))
      ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]);
    return query.watch();
  }

  /// Hard-deletes a recycled bill's rows (stock ledger history persists).
  /// Refuses live documents and locked-period dates.
  Future<void> purge(String id) async {
    await db.transaction(() async {
      final bill = await getById(id);
      if (bill == null) return;
      if (!bill.isDeleted) {
        throw StateError(
            'Move this bill to the recycle bin before deleting it '
            'permanently.');
      }
      await db.assertDateEditable(firmId, bill.billDate);
      await (db.delete(db.purchaseBillItems)
            ..where((t) => t.billId.equals(id)))
          .go();
      await (db.delete(db.purchaseBills)
            ..where((t) => t.id.equals(id) & t.firmId.equals(firmId)))
          .go();
      await db.auditRepository.log(
        action: 'purge',
        entity: 'purchase_bills',
        firmId: firmId,
        entityId: id,
        summary: 'Permanently deleted ${bill.docType} ${bill.number}',
      );
    });
  }

  Future<List<PurchaseBillItemEntity>> itemsFor(String billId) async {
    final query = db.select(db.purchaseBillItems)
      ..where((t) => t.billId.equals(billId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]);
    return query.get();
  }

  Future<List<PurchaseBillEntity>> list({
    String docType = 'bill',
    String? partyId,
    String search = '',
    DateTime? from,
    DateTime? to,
    int limit = 500,
  }) async {
    final query = db.select(db.purchaseBills)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.docType.equals(docType) &
          t.isDeleted.equals(false))
      ..orderBy([
        (t) => OrderingTerm.desc(t.billDate),
        (t) => OrderingTerm(expression: t.number)
      ]);
    if (partyId != null) {
      query.where((t) => t.partyId.equals(partyId));
    }
    if (from != null) {
      query.where((t) => t.billDate.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query.where((t) => t.billDate.isSmallerOrEqualValue(to));
    }
    if (search.trim().isNotEmpty) {
      final s = '%${search.trim().toLowerCase()}%';
      query.where((t) =>
          t.number.lower().like(s) | t.partyName.lower().like(s));
    }
    query.limit(limit);
    return query.get();
  }

  Stream<List<PurchaseBillEntity>> watchList({
    String docType = 'bill',
    String? partyId,
    DateTime? from,
    DateTime? to,
    int limit = 100,
  }) {
    final query = db.select(db.purchaseBills)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.docType.equals(docType) &
          t.isDeleted.equals(false))
      ..orderBy([
        (t) => OrderingTerm.desc(t.billDate),
      ]);
    if (partyId != null) {
      query.where((t) => t.partyId.equals(partyId));
    }
    if (from != null) {
      query.where((t) => t.billDate.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query.where((t) => t.billDate.isSmallerOrEqualValue(to));
    }
    query.limit(limit);
    return query.watch();
  }

  Future<void> applyPayment({
    required String billId,
    required double amount,
    DateTime? date,
  }) async {
    await db.transaction(() async {
      final doc = await getById(billId);
      if (doc == null) return;
      if (doc.isDeleted || doc.status == 'cancelled') {
        throw StateError(
            'Cannot record a payment against a cancelled or deleted bill.');
      }
      await db.assertDateEditable(firmId, date ?? doc.billDate);
      if (amount > doc.balanceDue + 0.001) {
        amount = doc.balanceDue;
      }
      final paid = doc.paidAmount + amount;
      final balance = doc.grandTotal - paid;
      final status =
          balance <= 0.001 ? 'paid' : (paid > 0.001 ? 'partial' : 'unpaid');
      await db.update(db.purchaseBills).replace(doc.copyWith(
            paidAmount: paid,
            balanceDue: balance < 0 ? 0 : balance,
            paymentStatus: status,
            updatedAt: DateTime.now(),
          ));
      await enqueue(
        firmId: firmId,
        entity: 'purchase_bills',
        entityId: billId,
        operation: 'update',
      );
    });
  }

  Future<double> totalPurchases({DateTime? from, DateTime? to}) async {
    final docs = await list(docType: 'bill', from: from, to: to, limit: 100000);
    var total = 0.0;
    for (final d in docs) {
      if (d.status == 'cancelled') continue;
      total += d.grandTotal;
    }
    return total;
  }

  Future<double> totalPayable() async {
    final docs = await list(docType: 'bill', limit: 100000);
    var total = 0.0;
    for (final d in docs) {
      if (d.status == 'cancelled') continue;
      total += d.balanceDue;
    }
    return total;
  }
}
