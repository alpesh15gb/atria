import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../../engine/gst_engine.dart';
import '../../utils/money.dart';
import '../../domain/member_role.dart';
import '../../domain/gst_registration.dart';
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
    String billId,
    int order,
    ComputedLine? computed,
  ) {
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

  /// TDS percentage deducted at source on this bill. Null/zero means none.
  final Decimal? tdsRate;

  /// The deductee's PAN, snapshotted onto the bill.
  ///
  /// **Taken from the party when the caller does not supply it**, because a
  /// bill entered through the purchase editor has the supplier on the line and
  /// their PAN on the party — and a TDS bill without it cannot produce a 26Q.
  /// The snapshot is still the value of record: editing the party's PAN
  /// afterwards must not rewrite what a February bill was filed under.
  final String? deducteePan;

  /// The TDS section — 192, 194, 194H, 195 and the rest.
  ///
  /// Snapshotted rather than derived, because the section depends on what the
  /// payment was *for*, and a business legitimately pays the same supplier
  /// under two sections in one year.
  final String? tdsSection;

  /// The rate the deduction was worked out at, beside [tdsRate] so a partly
  /// exempt bill can say so. Free real: the sections carry different rates, and
  /// one column would have to be the common denominator.
  final double tdsSectionRate;

  /// Resolved values. `Money.zero` isn't a compile-time constant, so the fields
  /// are nullable and default to zero here for readers that need a [Decimal].
  Decimal get invoiceDiscountPercentValue =>
      invoiceDiscountPercent ?? Money.zero;
  Decimal get invoiceDiscountAmountValue => invoiceDiscountAmount ?? Money.zero;
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
    this.tdsRate,
    this.deducteePan,
    this.tdsSection,
    this.tdsSectionRate = 0,
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

  Future<PurchaseBillEntity> save(
    PurchaseDraft draft, {
    bool affectStock = true,
    String? createdBy,
  }) async {
    db.assertPermission(Permission.createPurchases);
    final firm = await db.firmRepository.getById(firmId);
    if (firm == null) throw StateError('Business not found.');
    final previous = await getLiveById(draft.id);
    final itcEligible = previous?.itcEligible ?? firm.isGstRegistered;
    final split = draft.isInterState
        ? GstSplit.interState
        : GstSplit.intraState;
    final result = GstEngine.computeDocument(
      lines: draft.lines.map((l) => l.toTaxLine()).toList(),
      split: split,
      invoiceDiscountPercent: draft.invoiceDiscountPercentValue,
      invoiceDiscountAmount: draft.invoiceDiscountAmountValue,
      applyRoundOff: draft.applyRoundOff,
    );
    // TDS is deducted by the buyer from what the supplier is owed, on the
    // taxable value rather than on the GST that also goes to the government:
    // see [GstEngine.settlementTax].
    final tds = GstEngine.settlementTax(
      taxableValue: result.taxableValue,
      rate: draft.tdsRate,
    );
    final grandTotal =
        result.grandTotal +
        draft.shippingChargeValue +
        draft.otherChargesValue -
        tds;
    // The same backstop the sales repository has: `Money.tryParse` accepts a
    // leading `-`, so a pasted negative rate produced a negative bill that
    // `DocumentSettlement` then clamped to zero and reported as `paid`.
    //
    // Negative only, not zero: a ₹0 bill is a legitimate draft (lines not typed
    // yet) and a fully-discounted purchase, and refusing it would break real
    // flows. The Rate **cell** has no validator, so this layer is the one that
    // cannot be bypassed by an import or a deep link.
    if (draft.lines.any(
      (l) => l.rate < Decimal.zero || l.quantity < Decimal.zero,
    )) {
      throw ArgumentError(
        'A bill cannot be saved with a negative rate or quantity.',
      );
    }
    if (grandTotal < Decimal.zero) {
      throw ArgumentError(
        'A bill cannot be worth a negative amount — check the rate and '
        'discount on each line.',
      );
    }
    final now = DateTime.now();

    await db.transaction(() async {
      // An edit reuses the bill id. The old code ran the same INSERT as a new
      // bill, so editing a bill either threw on the duplicate id or, once it
      // got past that, reset paidAmount to 0 (forgetting recorded payments),
      // left the stale line rows behind and posted the stock-in twice.
      // `getLiveById`, not `getById`: a **binned** bill must not count as an
      // edit. `getById` has no `isDeleted` predicate, so a recycled bill took
      // the upsert path — which leaves `isDeleted` at the column default and so
      // silently resurrected it, re-posting its stock and re-counting its
      // payable. The sales repository has always made this distinction.
      final existing = await getLiveById(draft.id);
      final isEdit = existing != null;
      final createdAt = existing?.createdAt ?? now;

      // Period lock: same rule as sales (see sales_repository.save).
      await db.assertDateEditable(firmId, draft.billDate);
      if (isEdit) {
        await db.assertDateEditable(firmId, existing.billDate);
      }

      if (isEdit) {
        for (final old in await itemsFor(draft.id)) {
          if (!draft.lines.any((line) => line.id == old.id)) {
            await enqueue(firmId: firmId, entity: 'purchase_bill_items',
              entityId: old.id, operation: 'delete');
          }
        }
        await db.reverseStockForSource(firmId, draft.id);
        await (db.delete(
          db.purchaseBillItems,
        )..where((t) => t.billId.equals(draft.id))).go();
      }

      final paidAmount = existing?.paidAmount ?? 0.0;
      // One derivation for both columns (see [DocumentSettlement]). This write
      // used to store `grandTotal - paid` unclamped, so deleting a ₹3,000 line
      // off a ₹10,000 bill that had been paid in full wrote a **−₹3,000**
      // payable with a 'paid' status beside it, and totalPayable() then netted
      // that negative against every other supplier's balance.
      //
      // Only a bill is payable. A purchase order (nothing received) and a debit
      // note (goods returned, credit to come) carry no outstanding amount, and
      // their status is now derived from that stored zero rather than from the
      // unclamped difference — which is why they used to read "Unpaid" beside a
      // ₹0 balance for ever.
      final settlement = draft.docType == 'bill'
          ? DocumentSettlement.of(
              grandTotal: grandTotal.toDouble(),
              paidAmount: paidAmount,
            )
          : DocumentSettlement.settled;

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
        paymentStatus: Value(settlement.status),
        paidAmount: Value(paidAmount),
        balanceDue: Value(settlement.balance),
        partyName: Value(draft.partyName),
        partyGstin: Value(draft.partyGstin),
        partyGstType: Value(draft.partyGstType),
        partyPhone: Value(draft.partyPhone),
        billingAddress: Value(draft.billingAddress),
        placeOfSupply: Value(draft.placeOfSupply),
        isInterState: Value(draft.isInterState),
        reverseCharge: Value(itcEligible && draft.reverseCharge),
        itcEligible: Value(itcEligible),
        subTotal: Value(result.subTotal.toDouble()),
        itemDiscount: Value(result.itemDiscountTotal.toDouble()),
        invoiceDiscountPercent: Value(
          draft.invoiceDiscountPercentValue.toDouble(),
        ),
        invoiceDiscountAmount: Value(
          draft.invoiceDiscountAmountValue.toDouble(),
        ),
        shippingCharge: Value(draft.shippingChargeValue.toDouble()),
        otherCharges: Value(draft.otherChargesValue.toDouble()),
        taxableValue: Value(result.taxableValue.toDouble()),
        cgst: Value(result.cgstTotal.toDouble()),
        sgst: Value(result.sgstTotal.toDouble()),
        igst: Value(result.igstTotal.toDouble()),
        cess: Value(result.cessTotal.toDouble()),
        tds: Value(tds.toDouble()),
        tdsRate: Value((draft.tdsRate ?? Money.zero).toDouble()),
        // **Only snapshotted when TDS was actually deducted.** Writing the PAN
        // and the section onto a bill with no deduction would put a 26Q line in
        // the report for a bill that never had tax withheld from it — a
        // declaration of a deduction that did not happen.
        deducteePan: Value(
          tds > Money.zero
              ? await _deducteePan(draft)
              : null,
        ),
        tdsSection: Value(tds > Money.zero ? draft.tdsSection : null),
        tdsSectionRate:
            Value(tds > Money.zero ? draft.tdsSectionRate : 0.0),
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
        await db
            .into(db.purchaseBillItems)
            .insert(
              draft.lines[i].toCompanion(
                draft.id,
                i,
                result.lineFor(draft.lines[i].id),
              ),
            );
      }

      // Journal the line rows themselves — see the twin comment in
      // SalesRepository.save: without these a restored bill has totals but
      // no lines.
      for (final line in draft.lines) {
        await enqueue(
          firmId: firmId,
          entity: 'purchase_bill_items',
          entityId: line.id,
          operation: 'insert',
        );
      }

      if (affectStock && draft.docType != 'purchase_order') {
        for (final line in draft.lines) {
          if (line.itemId == null || line.quantity == Money.zero) continue;
          final sign = draft.docType == 'debit_note' ? -1.0 : 1.0;
          // The cost the goods came in at, on a bill: the line's net taxable
          // value per unit, taken from the tax engine's own result rather than
          // re-derived from `rate` — the engine has already apportioned both
          // the item discount and the invoice discount onto this line, and a
          // hand-rolled `rate × quantity − discount` is wrong in exactly the
          // cases `gst_engine.dart:441` documents (₹10 off ₹300 is 0.03, not
          // 1/30).
          //
          // **GST is excluded on purpose.** Input tax credit is money the shop
          // did not spend and can set off against output tax, so capitalising
          // it into stock value would inflate every margin by the GST rate. A
          // debit note (a return to supplier) leaves stock at the running
          // average instead, and passes nothing.
          final computed = result.lineFor(line.id);
          final taxable = itcEligible ? computed?.taxableValue : computed?.total;
          await db.stockMovementsInsert(
            firmId,
            line.itemId!,
            sign * line.quantity.toDouble(),
            draft.docType == 'debit_note' ? 'purchase_return' : 'purchase',
            'purchase_bills',
            draft.id,
            draft.number,
            draft.billDate,
            sourceLineId: line.id,
            unitCost: draft.docType == 'debit_note' || taxable == null
                ? null
                : (taxable / line.quantity).toDecimal(
                    scaleOnInfinitePrecision: 4,
                  ),
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

  /// The deductee's PAN for a TDS bill: the caller's, or the supplier's.
///
/// **The party's PAN is the fallback because that is where the editor has it.**
/// A bill typed through the purchase screen names the supplier, and their PAN is
/// on the party row — so a TDS bill entered the ordinary way would otherwise
/// have no PAN and produce an unusable 26Q. Null is still a real answer: a
/// supplier who has not given one is a supplier whose 26Q line has to say so,
/// and inventing a PAN for them is exactly the mistake the column's own
/// comment warns against.
Future<String?> _deducteePan(PurchaseDraft draft) async {
  final explicit = (draft.deducteePan ?? '').trim();
  if (explicit.isNotEmpty) return explicit;
  final partyId = draft.partyId;
  if (partyId == null) return null;
  final party = await (db.select(db.parties)
        ..where((p) => p.id.equals(partyId)))
      .getSingleOrNull();
  return (party?.pan ?? '').trim().isEmpty ? null : party!.pan!.trim();
}

Future<PurchaseBillEntity?> getById(String id) async {
    final query = db.select(db.purchaseBills)
      ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
    return query.getSingleOrNull();
  }

  /// The same row, but only if it is **not** in the recycle bin.
  ///
  /// `getById` answers "does this id exist", which is right for a lookup and
  /// wrong for a write. `save` used it to decide `isEdit`, so a binned bill
  /// counted as a live one: the write took the upsert path, which leaves
  /// `isDeleted` at the column default, silently resurrecting it - its stock
  /// re-posted and its payable re-counted. `SalesRepository.save` has always
  /// used `getLiveById` here, with a comment saying exactly why; this was the
  /// purchase side of the same hole.
  Future<PurchaseBillEntity?> getLiveById(String id) async {
    final query = db.select(db.purchaseBills)
      ..where((t) =>
          t.id.equals(id) & t.firmId.equals(firmId) & t.isDeleted.equals(false));
    return query.getSingleOrNull();
  }

  /// How a refusal names the row it refused — "Bill PUR-4", not a uuid.
  String _docLabel(PurchaseBillEntity bill) =>
      '${bill.docType == 'bill' ? 'Bill' : 'Document'} ${bill.number}';

  /// Soft-deletes into the document recycle bin (stock-in reversed, audit
  /// written, locked periods respected). See sales_repository.softDelete.
  ///
  /// Refuses a bill that is already in the bin: the guard used to live only in
  /// the UI that hides the action, so a second delete reversed the reversal
  /// and doubled the stock back in.
  Future<void> softDelete(String id, {String? actor}) async {
    db.assertPermission(Permission.softDelete);
    await db.transaction(() async {
      final bill = await getById(id);
      if (bill == null) return;
      if (bill.isDeleted) {
        throw StateError('${_docLabel(bill)} is already in the recycle bin.');
      }
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
        firmId: firmId,
        entity: 'purchase_bills',
        entityId: id,
        operation: 'delete',
      );
      await db.auditRepository.log(
        action: 'delete',
        entity: 'purchase_bills',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary:
            'Deleted ${bill.docType} ${bill.number}'
            ' for ${bill.partyName ?? "supplier"}',
      );
    });
  }

  /// Restores a soft-deleted bill and re-applies its stock effect. Bills
  /// add stock back in, debit notes (purchase returns) deduct it again —
  /// matching the sign each doc type posts on save, so delete+restore is
  /// net zero on the stock ledger.
  ///
  /// Refuses a bill that is not in the bin — re-posting a live bill's stock
  /// added its quantity a second time, with no state check at all.
  Future<void> restore(String id, {String? actor}) async {
    db.assertPermission(Permission.softDelete);
    await db.transaction(() async {
      final bill = await getById(id);
      if (bill == null) return;
      if (!bill.isDeleted) {
        throw StateError(
          '${_docLabel(bill)} is not in the recycle bin — there is nothing '
          'to restore.',
        );
      }
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
        final kind = bill.docType == 'debit_note'
            ? 'purchase_return'
            : 'purchase';
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
              sourceLineId: l.id,
              sourceNumber: bill.number,
              date: bill.billDate,
              // `taxableValue` is the line's net value — both discounts
              // already apportioned onto it, GST excluded — so dividing by
              // quantity is what the goods actually cost the shop per unit.
              // Using `total` instead would capitalise recoverable input tax
              // into stock value, which is a figure the shop never paid and
              // cannot deduct, and every margin built on it would be wrong by
              // the GST rate.
              unitCost: l.quantity == 0
                  ? null
                  : (Money.of(bill.itcEligible ? l.taxableValue : l.total) / Money.of(l.quantity)).toDecimal(
                      scaleOnInfinitePrecision: 4,
                    ),
            );
          }
        }
      }
      await enqueue(
        firmId: firmId,
        entity: 'purchase_bills',
        entityId: id,
        operation: 'update',
      );
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
    db.assertPermission(Permission.purge);
    await db.transaction(() async {
      final bill = await getById(id);
      if (bill == null) return;
      if (!bill.isDeleted) {
        throw StateError(
          'Move this bill to the recycle bin before deleting it '
          'permanently.',
        );
      }
      await db.assertDateEditable(firmId, bill.billDate);
      await (db.delete(
        db.purchaseBillItems,
      )..where((t) => t.billId.equals(id))).go();
      await (db.delete(
        db.purchaseBills,
      )..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).go();
      await enqueue(firmId: firmId, entity: 'purchase_bills', entityId: id, operation: 'delete');
      await db.auditRepository.log(
        action: 'purge',
        entity: 'purchase_bills',
        firmId: firmId,
        entityId: id,
        summary: 'Permanently deleted ${bill.docType} ${bill.number}',
      );
    });
  }

  /// Flags a purchase order as converted (after its bill was saved), so the
  /// list can badge it and the convert action cannot run twice. Mirrors
  /// SalesRepository.markConverted.
  Future<void> markConverted(String id, {String? actor}) async {
    await db.transaction(() async {
      final bill = await getById(id);
      if (bill == null) return;
      await db.assertDateEditable(firmId, bill.billDate);
      await db
          .update(db.purchaseBills)
          .replace(
            bill.copyWith(status: 'converted', updatedAt: DateTime.now()),
          );
      await enqueue(
        firmId: firmId,
        entity: 'purchase_bills',
        entityId: id,
        operation: 'update',
      );
      await db.auditRepository.log(
        action: 'update',
        entity: 'purchase_bills',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Converted ${bill.docType} ${bill.number} to bill',
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
      ..where(
        (t) =>
            t.firmId.equals(firmId) &
            t.docType.equals(docType) &
            t.isDeleted.equals(false),
      )
      ..orderBy([
        (t) => OrderingTerm.desc(t.billDate),
        (t) => OrderingTerm(expression: t.number),
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
      query.where(
        (t) => t.number.lower().like(s) | t.partyName.lower().like(s),
      );
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
      ..where(
        (t) =>
            t.firmId.equals(firmId) &
            t.docType.equals(docType) &
            t.isDeleted.equals(false),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.billDate)]);
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
          'Cannot record a payment against a cancelled or deleted bill.',
        );
      }
      await db.assertDateEditable(firmId, date ?? doc.billDate);
      if (amount > doc.balanceDue + 0.001) {
        amount = doc.balanceDue;
      }
      final paid = doc.paidAmount + amount;
      // Same derivation the save path uses (see [DocumentSettlement]).
      final settlement = DocumentSettlement.of(
        grandTotal: doc.grandTotal,
        paidAmount: paid,
      );
      await db
          .update(db.purchaseBills)
          .replace(
            doc.copyWith(
              paidAmount: paid,
              balanceDue: settlement.balance,
              paymentStatus: settlement.status,
              updatedAt: DateTime.now(),
            ),
          );
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
