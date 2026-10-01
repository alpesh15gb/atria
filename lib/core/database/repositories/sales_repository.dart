import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../../engine/gst_engine.dart';
import '../../utils/money.dart';
import '../app_database.dart';
import 'repository_extensions.dart';
import 'stock_movement_ids.dart';
import 'sync_mixin.dart';

/// Input model used by the sale editor screens.
class SalesLineDraft {
  final String id;
  final String? itemId;
  final String name;
  final String? hsn;
  final Decimal quantity;
  final String unit;
  final Decimal rate;
  final Decimal? discountPercent;
  final Decimal? discountAmount;
  final double gstRate;
  final double cessRate;
  final TaxMode taxMode;

  const SalesLineDraft({
    required this.id,
    this.itemId,
    required this.name,
    this.hsn,
    required this.quantity,
    required this.unit,
    required this.rate,
    this.discountPercent,
    this.discountAmount,
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
        discountAmount: discountAmount ?? Money.zero,
        gstRate: gstRate,
        cessRate: cessRate,
        taxMode: taxMode,
      );

  /// Writes the resolved per-line tax figures. These columns back the detail
  /// screen's line table and the PDF's item grid, so leaving them out makes
  /// every line read ₹0.00 taxable / ₹0.00 total on a saved document.
  SalesInvoiceItemsCompanion toCompanion(
      String invoiceId, int order, ComputedLine? computed) {
    return SalesInvoiceItemsCompanion.insert(
      id: id,
      invoiceId: invoiceId,
      itemId: Value(itemId),
      name: name,
      hsn: Value(hsn),
      quantity: quantity.toDouble(),
      unit: Value(unit),
      rate: rate.toDouble(),
      discountPercent: Value((discountPercent ?? Money.zero).toDouble()),
      discountAmount: Value((discountAmount ?? Money.zero).toDouble()),
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

class SalesDraft {
  final String id;
  final String number;
  final String docType; // invoice | quotation | sales_order | delivery_note | credit_note
  final String? partyId;
  final DateTime invoiceDate;
  final DateTime? dueDate;
  final String status;
  final List<SalesLineDraft> lines;
  final String? partyName;
  final String? partyGstin;
  final String? partyGstType;
  final String? partyPhone;
  final String? billingAddress;
  final String? shippingAddress;
  final String? placeOfSupply;
  final bool isInterState;
  final bool reverseCharge;
  final bool isExport;
  final String? exportType;
  final Decimal? invoiceDiscountPercent;
  final Decimal? invoiceDiscountAmount;
  final Decimal? shippingCharge;
  /// TCS percentage, as entered on the invoice (or the firm's default rate).
  /// Null/zero means no tax was collected at source.
  final Decimal? tcsRate;
  final bool applyRoundOff;
  final String? notes;
  final String? terms;
  final int sequence;

  /// Resolved values. `Money.zero` isn't a compile-time constant, so the fields
  /// are nullable and default to zero here for readers that need a [Decimal].
  Decimal get invoiceDiscountPercentValue =>
      invoiceDiscountPercent ?? Money.zero;
  Decimal get invoiceDiscountAmountValue =>
      invoiceDiscountAmount ?? Money.zero;
  Decimal get shippingChargeValue => shippingCharge ?? Money.zero;

  const SalesDraft({
    required this.id,
    required this.number,
    required this.docType,
    this.partyId,
    required this.invoiceDate,
    this.dueDate,
    this.status = 'confirmed',
    required this.lines,
    this.partyName,
    this.partyGstin,
    this.partyGstType,
    this.partyPhone,
    this.billingAddress,
    this.shippingAddress,
    this.placeOfSupply,
    this.isInterState = false,
    this.reverseCharge = false,
    this.isExport = false,
    this.exportType,
    this.invoiceDiscountPercent,
    this.invoiceDiscountAmount,
    this.shippingCharge,
    this.tcsRate,
    this.applyRoundOff = true,
    this.notes,
    this.terms,
    this.sequence = 0,
  });

  SalesDraft copyWith({
    String? id,
    String? number,
    String? docType,
    Value<String?>? partyId,
    DateTime? invoiceDate,
    DateTime? dueDate,
    String? status,
    List<SalesLineDraft>? lines,
    String? partyName,
    String? partyGstin,
    String? partyGstType,
    String? partyPhone,
    String? billingAddress,
    String? shippingAddress,
    String? placeOfSupply,
    bool? isInterState,
    bool? reverseCharge,
    bool? isExport,
    String? exportType,
    Decimal? invoiceDiscountPercent,
    Decimal? invoiceDiscountAmount,
    Decimal? shippingCharge,
    Decimal? tcsRate,
    bool? applyRoundOff,
    String? notes,
    String? terms,
    int? sequence,
  }) {
    return SalesDraft(
      id: id ?? this.id,
      number: number ?? this.number,
      docType: docType ?? this.docType,
      partyId: partyId == null ? this.partyId : partyId.value,
      invoiceDate: invoiceDate ?? this.invoiceDate,
      dueDate: dueDate ?? this.dueDate,
      status: status ?? this.status,
      lines: lines ?? this.lines,
      partyName: partyName ?? this.partyName,
      partyGstin: partyGstin ?? this.partyGstin,
      partyGstType: partyGstType ?? this.partyGstType,
      partyPhone: partyPhone ?? this.partyPhone,
      billingAddress: billingAddress ?? this.billingAddress,
      shippingAddress: shippingAddress ?? this.shippingAddress,
      placeOfSupply: placeOfSupply ?? this.placeOfSupply,
      isInterState: isInterState ?? this.isInterState,
      reverseCharge: reverseCharge ?? this.reverseCharge,
      isExport: isExport ?? this.isExport,
      exportType: exportType ?? this.exportType,
      invoiceDiscountPercent:
          invoiceDiscountPercent ?? this.invoiceDiscountPercent,
      invoiceDiscountAmount:
          invoiceDiscountAmount ?? this.invoiceDiscountAmount,
      shippingCharge: shippingCharge ?? this.shippingCharge,
      tcsRate: tcsRate ?? this.tcsRate,
      applyRoundOff: applyRoundOff ?? this.applyRoundOff,
      notes: notes ?? this.notes,
      terms: terms ?? this.terms,
      sequence: sequence ?? this.sequence,
    );
  }
}

/// Reads/writes sales documents of every kind.
class SalesRepository with SyncQueueMixin {
  SalesRepository(this.db, this.firmId);

  @override
  final AppDatabase db;

  final String firmId;

  /// Writes a document and its lines atomically, applying stock effects.
  Future<SalesInvoiceEntity> save(SalesDraft draft,
      {bool affectStock = true, String? createdBy}) async {
    // The caller resolves the split from the firm's state vs the place of
    // supply; [isInterState] is the stored denormalized flag.
    final split = draft.isInterState ? GstSplit.interState : GstSplit.intraState;
    final result = GstEngine.computeDocument(
      lines: draft.lines.map((l) => l.toTaxLine()).toList(),
      split: split,
      invoiceDiscountPercent: draft.invoiceDiscountPercentValue,
      invoiceDiscountAmount: draft.invoiceDiscountAmountValue,
      applyRoundOff: draft.applyRoundOff,
    );
    // TCS rides on top of the tax invoice value and on the taxable value, not
    // on the tax: see [GstEngine.settlementTax]. Shipping is a charge the buyer
    // owes but is not consideration for the goods, so it is excluded from the
    // TCS base the same way GST is.
    final tcs = GstEngine.settlementTax(
      taxableValue: result.taxableValue,
      rate: draft.tcsRate,
    );
    final grandTotal = result.grandTotal +
        draft.shippingChargeValue +
        tcs;
    final now = DateTime.now();

    await db.transaction(() async {
      // An edit reuses the document id (the caller keeps it), so this branch
      // has to be a replace rather than an insert. The historical problems
      // here were: the plain INSERT threw on the duplicate id, the old line
      // rows stayed behind and duplicated on the detail/PDF view, and the
      // stock deduction was posted a second time on top of the first.
      final existing = await getLiveById(draft.id);
      final isEdit = existing != null;
      final createdAt = existing?.createdAt ?? now;

      // Period lock: refuse NEW documents dated in a locked period, and
      // edits only when the document's own date is locked (its totals may
      // still be corrected forward-dated).
      await db.assertDateEditable(firmId, draft.invoiceDate);
      if (isEdit) {
        await db.assertDateEditable(firmId, existing.invoiceDate);
      }

      if (isEdit) {
        await db.reverseStockForSource(firmId, draft.id);
        await (db.delete(db.salesInvoiceItems)
              ..where((t) => t.invoiceId.equals(draft.id)))
            .go();
      }

      // Payments already recorded against this id must survive the re-save;
      // balanceDue and paymentStatus are derived from them, not reset.
      final paidAmount = existing?.paidAmount ?? 0.0;
      final balance = grandTotal.toDouble() - paidAmount;
      final paymentStatus = balance <= 0.001
          ? 'paid'
          : (paidAmount > 0.001 ? 'partial' : 'unpaid');

      final companion = SalesInvoicesCompanion.insert(
        id: draft.id,
        firmId: firmId,
        docType: Value(draft.docType),
        number: draft.number,
        partyId: Value(draft.partyId),
        invoiceDate: draft.invoiceDate,
        dueDate: Value(draft.dueDate),
        status: Value(draft.status),
        paymentStatus: Value(paymentStatus),
        paidAmount: Value(paidAmount),
        balanceDue:
            Value(draft.docType == 'invoice' ? balance : 0),
        partyName: Value(draft.partyName),
        partyGstin: Value(draft.partyGstin),
        partyGstType: Value(draft.partyGstType),
        partyPhone: Value(draft.partyPhone),
        billingAddress: Value(draft.billingAddress),
        shippingAddress: Value(draft.shippingAddress),
        placeOfSupply: Value(draft.placeOfSupply),
        isInterState: Value(draft.isInterState),
        reverseCharge: Value(draft.reverseCharge),
        isExport: Value(draft.isExport),
        exportType: Value(draft.exportType),
        subTotal: Value(result.subTotal.toDouble()),
        itemDiscount: Value(result.itemDiscountTotal.toDouble()),
        invoiceDiscountPercent:
            Value(draft.invoiceDiscountPercentValue.toDouble()),
        invoiceDiscountAmount:
            Value(draft.invoiceDiscountAmountValue.toDouble()),
        shippingCharge: Value(draft.shippingChargeValue.toDouble()),
        taxableValue: Value(result.taxableValue.toDouble()),
        cgst: Value(result.cgstTotal.toDouble()),
        sgst: Value(result.sgstTotal.toDouble()),
        igst: Value(result.igstTotal.toDouble()),
        cess: Value(result.cessTotal.toDouble()),
        tcs: Value(tcs.toDouble()),
        tcsRate: Value((draft.tcsRate ?? Money.zero).toDouble()),
        roundOff: Value(result.roundOff.toDouble()),
        grandTotal: Value(grandTotal.toDouble()),
        notes: Value(draft.notes),
        terms: Value(draft.terms),
        createdBy: Value(createdBy),
        createdAt: Value(createdAt),
        updatedAt: Value(now),
        sequence: Value(draft.sequence),
      );

      if (isEdit) {
        await db.into(db.salesInvoices).insertOnConflictUpdate(companion);
      } else {
        await db.into(db.salesInvoices).insert(companion);
      }

      for (var i = 0; i < draft.lines.length; i++) {
        await db.into(db.salesInvoiceItems).insert(draft.lines[i]
            .toCompanion(draft.id, i, result.lineFor(draft.lines[i].id)));
      }

      // Journal the line rows themselves. The document's payload is what a
      // pull restores first; without these a restored invoice would arrive
      // with its totals but none of its lines, because lines are separate
      // rows and the edit path re-inserts them with fresh ids.
      for (final line in draft.lines) {
        await enqueue(
          firmId: firmId,
          entity: 'sales_invoice_items',
          entityId: line.id,
          operation: 'insert',
        );
      }

      // Orders and estimates never move stock: a sales order is a promise,
      // not a delivery — the invoice raised against it does the stock and
      // ledger work (a delivery note ships on paper the same way). Save and
      // restore must agree on this set, or delete+restore drifts the
      // ledger. The Vyapar importer relies on it too: it passes
      // affectStock: false for orders/estimates, but this guard is what
      // keeps a direct save from deducting.
      const stocklessDocTypes = {
        'quotation',
        'sales_order',
        'delivery_note',
      };
      if (affectStock && !stocklessDocTypes.contains(draft.docType)) {
        for (final line in draft.lines) {
          if (line.itemId == null || line.quantity == Money.zero) continue;
          final sign = draft.docType == 'credit_note' ? 1.0 : -1.0;
          await db.stockMovementsInsert(
            firmId,
            line.itemId!,
            sign * line.quantity.toDouble(),
            draft.docType == 'credit_note' ? 'sale_return' : 'sale',
            'sales_invoices',
            draft.id,
            draft.number,
            draft.invoiceDate,
          );
        }
      }

      await enqueue(
        firmId: firmId,
        entity: 'sales_invoices',
        entityId: draft.id,
        operation: isEdit ? 'update' : 'insert',
      );
    });

    return (await getById(draft.id))!;
  }

  Future<SalesInvoiceEntity?> getById(String id) async {
    final query = db.select(db.salesInvoices)
      ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
    return query.getSingleOrNull();
  }

  /// The live (not-recycled) document, for edit/save paths. Re-saving a
  /// binned document used to silently resurrect it, rewrite its lines and
  /// re-post its stock — the editor must load through this.
  Future<SalesInvoiceEntity?> getLiveById(String id) async {
    final query = db.select(db.salesInvoices)
      ..where((t) =>
          t.id.equals(id) & t.firmId.equals(firmId) & t.isDeleted.equals(false));
    return query.getSingleOrNull();
  }

  Future<List<SalesInvoiceItemEntity>> itemsFor(String invoiceId) async {
    final query = db.select(db.salesInvoiceItems)
      ..where((t) => t.invoiceId.equals(invoiceId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]);
    return query.get();
  }

  /// Every line of every invoice in [invoiceIds], grouped by invoice — one
  /// query instead of one per document.
  ///
  /// Reports that need the lines of a whole month were calling [itemsFor]
  /// inside a loop, which is an N+1 against a local database: fine on twenty
  /// invoices, visibly slow on a thousand. Capped at 900 ids per statement
  /// because SQLite's default parameter limit is 999 and a firm can have more
  /// documents than that in a year.
  Future<Map<String, List<SalesInvoiceItemEntity>>> itemsForMany(
    List<String> invoiceIds,
  ) async {
    final grouped = <String, List<SalesInvoiceItemEntity>>{};
    if (invoiceIds.isEmpty) return grouped;
    const chunkSize = 900;
    for (var i = 0; i < invoiceIds.length; i += chunkSize) {
      final chunk = invoiceIds.sublist(
        i,
        i + chunkSize > invoiceIds.length ? invoiceIds.length : i + chunkSize,
      );
      final query = db.select(db.salesInvoiceItems)
        ..where((t) => t.invoiceId.isIn(chunk) & t.isDeleted.equals(false))
        ..orderBy([
          (t) => OrderingTerm(expression: t.invoiceId),
          (t) => OrderingTerm(expression: t.sortOrder),
        ]);
      for (final line in await query.get()) {
        (grouped[line.invoiceId] ??= []).add(line);
      }
    }
    return grouped;
  }

  /// Converts a stored document back into an editable draft.
  Future<SalesDraft> toDraft(SalesInvoiceEntity doc) async {
    final lines = await itemsFor(doc.id);
    return SalesDraft(
      id: doc.id,
      number: doc.number,
      docType: doc.docType,
      partyId: doc.partyId,
      invoiceDate: doc.invoiceDate,
      dueDate: doc.dueDate,
      status: doc.status,
      lines: lines
          .map((l) => SalesLineDraft(
                id: l.id,
                itemId: l.itemId,
                name: l.name,
                hsn: l.hsn,
                quantity: Decimal.parse(l.quantity.toString()),
                unit: l.unit,
                rate: Decimal.parse(l.rate.toString()),
                discountPercent: Decimal.parse(l.discountPercent.toString()),
                discountAmount: Decimal.parse(l.discountAmount.toString()),
                gstRate: l.gstRate,
                cessRate: l.cessRate,
                taxMode: l.taxMode == 'inclusive'
                    ? TaxMode.inclusive
                    : TaxMode.exclusive,
              ))
          .toList(),
      partyName: doc.partyName,
      partyGstin: doc.partyGstin,
      partyGstType: doc.partyGstType,
      partyPhone: doc.partyPhone,
      billingAddress: doc.billingAddress,
      shippingAddress: doc.shippingAddress,
      placeOfSupply: doc.placeOfSupply,
      isInterState: doc.isInterState,
      reverseCharge: doc.reverseCharge,
      isExport: doc.isExport,
      exportType: doc.exportType,
      invoiceDiscountPercent:
          Decimal.parse(doc.invoiceDiscountPercent.toString()),
      invoiceDiscountAmount:
          Decimal.parse(doc.invoiceDiscountAmount.toString()),
      shippingCharge: Decimal.parse(doc.shippingCharge.toString()),
      applyRoundOff: doc.roundOff.abs() > 0.000001,
      notes: doc.notes,
      terms: doc.terms,
      sequence: doc.sequence,
    );
  }

  /// Lists documents filtered by type.
  Future<List<SalesInvoiceEntity>> list({
    String docType = 'invoice',
    String? partyId,
    String search = '',
    DateTime? from,
    DateTime? to,
    String paymentStatus = '',
    int limit = 500,
  }) async {
    final query = db.select(db.salesInvoices)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.docType.equals(docType) &
          t.isDeleted.equals(false))
      ..orderBy([
        (t) => OrderingTerm.desc(t.invoiceDate),
        (t) => OrderingTerm(expression: t.number)
      ]);
    if (partyId != null) {
      query.where((t) => t.partyId.equals(partyId));
    }
    if (paymentStatus.isNotEmpty) {
      query.where((t) => t.paymentStatus.equals(paymentStatus));
    }
    if (from != null) {
      query.where((t) => t.invoiceDate.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query.where((t) => t.invoiceDate.isSmallerOrEqualValue(to));
    }
    if (search.trim().isNotEmpty) {
      final s = '%${search.trim().toLowerCase()}%';
      query.where((t) =>
          t.number.lower().like(s) | t.partyName.lower().like(s));
    }
    query.limit(limit);
    return query.get();
  }

  /// Unpaid invoices past their due date, most overdue first — the payment
  /// reminders list. Any not-cancelled, not-binned document with a balance
  /// counts (a 'delivered' invoice is just as overdue as a 'confirmed' one).
  Stream<List<SalesInvoiceEntity>> watchOverdue({int limit = 500}) {
    final query = db.select(db.salesInvoices)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.docType.equals('invoice') &
          t.isDeleted.equals(false) &
          t.status.equals('cancelled').not() &
          t.status.equals('converted').not() &
          t.balanceDue.isBiggerThanValue(0.001) &
          t.dueDate.isNotNull())
      ..orderBy([(t) => OrderingTerm.asc(t.dueDate)])
      ..limit(limit);
    return query.watch();
  }

  Stream<List<SalesInvoiceEntity>> watchList({
    String docType = 'invoice',
    String? partyId,
    String search = '',
    DateTime? from,
    DateTime? to,
    int limit = 100,
  }) {
    final query = db.select(db.salesInvoices)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.docType.equals(docType) &
          t.isDeleted.equals(false))
      ..orderBy([
        (t) => OrderingTerm.desc(t.invoiceDate),
        (t) => OrderingTerm(expression: t.number)
      ]);
    if (partyId != null) {
      query.where((t) => t.partyId.equals(partyId));
    }
    if (from != null) {
      query.where((t) => t.invoiceDate.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query.where((t) => t.invoiceDate.isSmallerOrEqualValue(to));
    }
    if (search.trim().isNotEmpty) {
      final s = '%${search.trim().toLowerCase()}%';
      query.where((t) =>
          t.number.lower().like(s) | t.partyName.lower().like(s));
    }    query.limit(limit);
    return query.watch();
  }

  /// Every non-deleted sales document (invoices, quotations, orders, notes)
  /// for one party, newest first — the Parties master-detail's right pane.
  Stream<List<SalesInvoiceEntity>> watchForParty(String partyId,
      {int limit = 500}) {
    final query = db.select(db.salesInvoices)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.partyId.equals(partyId) &
          t.isDeleted.equals(false))
      ..orderBy([
        (t) => OrderingTerm.desc(t.invoiceDate),
        (t) => OrderingTerm(expression: t.number)
      ])
      ..limit(limit);
    return query.watch();
  }




  Future<void> markCancelled(String id, {String? actor}) async {
    await db.transaction(() async {
      final doc = await getById(id);
      if (doc == null) return;
      await db.assertDateEditable(firmId, doc.invoiceDate);
      // A cancelled invoice stops chasing money: its balance columns zero
      // out so outstanding/ageing never count it (H3 parity at the row level).
      await db.update(db.salesInvoices).replace(doc.copyWith(
            status: 'cancelled',
            balanceDue: 0,
            paidAmount: doc.paidAmount,
            paymentStatus: doc.paidAmount > 0.001 ? 'paid' : 'unpaid',
            updatedAt: DateTime.now(),
          ));
      await enqueue(
        firmId: firmId,
        entity: 'sales_invoices',
        entityId: id,
        operation: 'update',
      );
      await db.auditRepository.log(
        action: 'update',
        entity: 'sales_invoices',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Cancelled ${doc.docType} ${doc.number}',
      );
    });
  }

  /// Soft-deletes into the document recycle bin and reverses the stock the
  /// invoice deducted. Audited; refused when the document date is inside a
  /// locked period.
  Future<void> softDelete(String id, {String? actor}) async {
    await db.transaction(() async {
      final doc = await getById(id);
      if (doc == null) return;
      await db.assertDateEditable(firmId, doc.invoiceDate);
      await db.reverseStockForSource(firmId, id);
      await (db.update(db.salesInvoices)..where((t) => t.id.equals(id))).write(
        SalesInvoicesCompanion(
          isDeleted: const Value(true),
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await enqueue(
          firmId: firmId, entity: 'sales_invoices', entityId: id,
          operation: 'delete');
      await db.auditRepository.log(
        action: 'delete',
        entity: 'sales_invoices',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Deleted ${doc.docType} ${doc.number}'
            ' for ${doc.partyName ?? "walk-in"}',
      );
    });
  }

  /// Restores a soft-deleted document and re-applies its stock effect.
  Future<void> restore(String id, {String? actor}) async {
    await db.transaction(() async {
      final doc = await getById(id);
      if (doc == null) return;
      await db.assertDateEditable(firmId, doc.invoiceDate);
      await (db.update(db.salesInvoices)..where((t) => t.id.equals(id))).write(
        SalesInvoicesCompanion(
          isDeleted: const Value(false),
          deletedAt: const Value(null),
          updatedAt: Value(DateTime.now()),
        ),
      );
      // Stock only moves for documents that actually move goods (save
      // excludes orders/estimates/notes the same way, so delete+restore
      // lands net zero instead of adding stock a quotation never took). A
      // cancelled invoice's movements were reversed by softDelete, so
      // restoring one must not re-apply them either.
      final movesStock =
          doc.docType == 'invoice' || doc.docType == 'credit_note';
      if (movesStock && doc.status != 'cancelled') {
        final sign = doc.docType == 'credit_note' ? 1.0 : -1.0;
        final kind = doc.docType == 'credit_note' ? 'sale_return' : 'sale';
        final items = await itemsFor(id);
        for (final l in items) {
          if (l.itemId != null) {
            final itemRepo = db.itemRepositoryFor(firmId);
            await itemRepo.applyStockEffect(
              itemId: l.itemId!,
              quantity: sign * l.quantity,
              kind: kind,
              source: 'sales_invoices',
              sourceId: id,
              sourceNumber: doc.number,
              date: doc.invoiceDate,
            );
          }
        }
      }
      await enqueue(
          firmId: firmId, entity: 'sales_invoices', entityId: id,
          operation: 'update');
      await db.auditRepository.log(
        action: 'restore',
        entity: 'sales_invoices',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Restored ${doc.docType} ${doc.number}',
      );
    });
  }

  /// Rows sitting in the document recycle bin, newest deletion first.
  Stream<List<SalesInvoiceEntity>> watchDeleted() {
    final query = db.select(db.salesInvoices)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(true))
      ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]);
    return query.watch();
  }

  /// Hard-deletes a recycled document's rows (the line rows go too; stock
  /// ledger history stays by design). Refuses live documents — soft-delete
  /// first so the stock deduction is reversed before the rows vanish — and
  /// refuses dates inside a locked period.
  Future<void> purge(String id) async {
    await db.transaction(() async {
      final doc = await getById(id);
      if (doc == null) return;
      if (!doc.isDeleted) {
        throw StateError(
            'Move this document to the recycle bin before deleting it '
            'permanently.');
      }
      await db.assertDateEditable(firmId, doc.invoiceDate);
      await (db.delete(db.salesInvoiceItems)
            ..where((t) => t.invoiceId.equals(id)))
          .go();
      await (db.delete(db.salesInvoices)
            ..where((t) => t.id.equals(id) & t.firmId.equals(firmId)))
          .go();
      await db.auditRepository.log(
        action: 'purge',
        entity: 'sales_invoices',
        firmId: firmId,
        entityId: id,
        summary: 'Permanently deleted ${doc.docType} ${doc.number}',
      );
    });
  }

  /// Flags a quotation / sales order as converted (after its invoice was
  /// saved), so lists can badge it and the convert action cannot run twice.
  Future<void> markConverted(String id, {String? actor}) async {
    await db.transaction(() async {
      final doc = await getById(id);
      if (doc == null) return;
      await db.assertDateEditable(firmId, doc.invoiceDate);
      await db.update(db.salesInvoices)
          .replace(doc.copyWith(status: 'converted', updatedAt: DateTime.now()));
      await enqueue(
        firmId: firmId,
        entity: 'sales_invoices',
        entityId: id,
        operation: 'update',
      );
      await db.auditRepository.log(
        action: 'update',
        entity: 'sales_invoices',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Converted ${doc.docType} ${doc.number} to invoice',
      );
    });
  }

  /// Records a payment against a sales invoice and updates its balances.
  /// Guards: refuses cancelled/binned documents, refuses dates inside a
  /// locked period, and clamps [amount] at the outstanding balance (the UI
  /// caps earlier; the repository is the enforcement point).
  Future<void> applyPayment({
    required String invoiceId,
    required double amount,
    DateTime? date,
  }) async {
    await db.transaction(() async {
      final doc = await getById(invoiceId);
      if (doc == null) return;
      if (doc.isDeleted || doc.status == 'cancelled') {
        throw StateError(
            'Cannot record a payment against a cancelled or deleted '
            'document.');
      }
      await db.assertDateEditable(firmId, date ?? doc.invoiceDate);
      if (amount > doc.balanceDue + 0.001) {
        amount = doc.balanceDue;
      }
      final paid = doc.paidAmount + amount;
      final balance = doc.grandTotal - paid;
      final status = balance <= 0.001
          ? 'paid'
          : (paid > 0.001 ? 'partial' : 'unpaid');
      await db.update(db.salesInvoices).replace(doc.copyWith(
            paidAmount: paid,
            balanceDue: balance < 0 ? 0 : balance,
            paymentStatus: status,
            updatedAt: DateTime.now(),
          ));
      await enqueue(
        firmId: firmId,
        entity: 'sales_invoices',
        entityId: invoiceId,
        operation: 'update',
      );
    });
  }

  Future<double> totalSales({
    DateTime? from,
    DateTime? to,
    bool paidOnly = false,
  }) async {
    final docs = await list(docType: 'invoice', from: from, to: to, limit: 100000);
    var total = 0.0;
    for (final d in docs) {
      if (d.status == 'cancelled') continue;
      total += paidOnly ? d.paidAmount : d.grandTotal;
    }
    return total;
  }

  Future<double> totalOutstanding() async {
    final docs = await list(docType: 'invoice', limit: 100000);
    var total = 0.0;
    for (final d in docs) {
      if (d.status == 'cancelled') continue;
      total += d.balanceDue;
    }
    return total;
  }
}

/// Extension that keeps the stock-movement write next to the repository that
/// owns it, without forcing a circular import on the Drift class.
extension StockMovementsInsert on AppDatabase {
  Future<void> stockMovementsInsert(
    String firmId,
    String itemId,
    double quantity,
    String kind,
    String source,
    String sourceId,
    String sourceNumber,
    DateTime date,
  ) async {
    final item = await (select(items)
          ..where((t) => t.id.equals(itemId) & t.firmId.equals(firmId)))
        .getSingleOrNull();
    if (item == null) {
      throw StateError('Stock movement for unknown item $itemId.');
    }
    if (item.isService || item.stockType != 'tracked') {
      // Services and untracked goods have no stock to move.
      return;
    }
    // Negative stock is ALLOWED at the repository layer: small traders bill
    // before their purchase entries exist, and hard-blocking billing over
    // bookkeeping order is worse than a negative ledger line (Vyapar warns
    // rather than blocks too). The movement records the true balance; the
    // stock screen's low-stock view makes it visible.
    final newBalance = item.currentStock + quantity;
    await update(items).replace(
        item.copyWith(currentStock: newBalance, updatedAt: DateTime.now()));
    final movementId = newStockMovementId();
    await into(stockMovements).insert(StockMovementsCompanion.insert(
      id: movementId,
      firmId: firmId,
      itemId: itemId,
      kind: kind,
      quantity: quantity,
      balanceAfter: Value(newBalance),
      source: source,
      sourceId: Value(sourceId),
      sourceNumber: Value(sourceNumber),
      date: date,
    ));

    // Movements are the stock ledger of record (current_stock is derived from
    // them), so a restore has to carry them. Journaled here because this
    // extension lives below the repositories that would otherwise enqueue it.
    await _MovementOutbox(this).enqueue(
      firmId: firmId,
      entity: 'stock_movements',
      entityId: movementId,
      operation: 'insert',
    );
  }

  /// Posts the equal-and-opposite of every movement [sourceId] recorded, so a
  /// document being rewritten lands at the net effect of its new lines rather
  /// than its old lines plus its new ones.
  Future<void> reverseStockForSource(String firmId, String sourceId) async {
    final movements = await (select(stockMovements)
          ..where((t) => t.firmId.equals(firmId) & t.sourceId.equals(sourceId)))
        .get();
    for (final m in movements) {
      final item = await (select(items)
            ..where((t) => t.id.equals(m.itemId) & t.firmId.equals(firmId)))
          .getSingleOrNull();
      if (item == null) continue;
      final newBalance = item.currentStock - m.quantity;
      await update(items).replace(
          item.copyWith(currentStock: newBalance, updatedAt: DateTime.now()));
      final reversalId = newStockMovementId();
      await into(stockMovements).insert(StockMovementsCompanion.insert(
        id: reversalId,
        firmId: firmId,
        itemId: m.itemId,
        kind: m.kind,
        quantity: -m.quantity,
        balanceAfter: Value(newBalance),
        source: m.source,
        sourceId: Value(sourceId),
        sourceNumber: Value(m.sourceNumber),
        // Reversals are bookkeeping events, not transactions: date them at
        // the original movement's date so the ledger stays chronologically
        // consistent with the document that produced it.
        date: m.date,
        notes: const Value('reversal'),
      ));
      await _MovementOutbox(this).enqueue(
        firmId: firmId,
        entity: 'stock_movements',
        entityId: reversalId,
        operation: 'insert',
      );
    }
  }
}

/// Outbox access for [StockMovementsInsert], which is an extension on the
/// database and has no repository of its own to inherit the sync mixin.
class _MovementOutbox with SyncQueueMixin {
  _MovementOutbox(this.db);

  @override
  final AppDatabase db;
}
