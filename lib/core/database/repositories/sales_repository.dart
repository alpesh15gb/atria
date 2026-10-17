import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../../domain/document_status.dart';
import '../../domain/gst_registration.dart';
import '../../domain/member_role.dart';
import '../../engine/gst_engine.dart';
import '../../utils/money.dart';
import '../app_database.dart';
import '../costing/moving_average.dart';
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
    String invoiceId,
    int order,
    ComputedLine? computed,
  ) {
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
  final String
  docType; // invoice | quotation | sales_order | delivery_note | credit_note
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
  Decimal get invoiceDiscountAmountValue => invoiceDiscountAmount ?? Money.zero;
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

/// The one place a document's outstanding balance and its payment status are
/// derived. Every write path — save (insert and edit), applyPayment, cancel —
/// builds one of these instead of computing the two figures separately, which
/// is what let a document end up storing a **negative** balance while its
/// status still read 'paid'.
///
/// The rules, once:
///  * [balance] is clamped at zero. A document cannot owe less than nothing;
///    a negative payable nets against every other party's outstanding in
///    `totalOutstanding`, which is how one over-edited bill corrupts a total.
///  * [status] follows [balance], never the raw difference, so the two columns
///    can never contradict each other.
///  * [overpaid] is the residue that clamping hides: money already received
///    (or already paid out) that exceeds what the document is now worth. The
///    balance stays honest at 0, but the user has to be told, because the
///    payments ledger still records the full amount.
class DocumentSettlement {
  const DocumentSettlement({
    required this.balance,
    required this.status,
    required this.overpaid,
  });

  /// [grandTotal] minus what is already settled, floored at zero.
  final double balance;

  /// 'paid' | 'partial' | 'unpaid'.
  final String status;

  /// Payments recorded against the document exceed its value.
  final bool overpaid;

  /// A document that carries no outstanding balance at all: every document
  /// type except invoice/bill (an order, a quotation, a note is not payable —
  /// the invoice or bill raised against it is), and a cancelled document
  /// whose balance the cancel path zeroes out so ageing stops counting it.
  ///
  /// These used to store a ₹0 balance beside a status derived from the
  /// unclamped difference, so a debit note permanently read "Unpaid" next to
  /// nothing owed.
  static const settled = DocumentSettlement(
    balance: 0,
    status: 'paid',
    overpaid: false,
  );

  /// Derives both figures from what the document is worth and what has
  /// already been settled against it. [Tolerance] keeps a sub-paisa residue
  /// from reading as an unpaid balance while still printing ₹0.00.
  factory DocumentSettlement.of({
    required double grandTotal,
    required double paidAmount,
    double tolerance = 0.001,
  }) {
    final outstanding = grandTotal - paidAmount;
    return DocumentSettlement(
      balance: outstanding < 0 ? 0 : outstanding,
      status: outstanding <= tolerance
          ? 'paid'
          : (paidAmount > tolerance ? 'partial' : 'unpaid'),
      overpaid: outstanding < -tolerance,
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
  Future<SalesInvoiceEntity> save(
    SalesDraft draft, {
    bool affectStock = true,
    String? createdBy,
  }) async {
    db.assertPermission(Permission.createSales);
    final firm = await db.firmRepository.getById(firmId);
    if (firm == null) throw StateError('Business not found.');
    final previous = await getLiveById(draft.id);
    final historicalTax =
        previous != null &&
        previous.cgst + previous.sgst + previous.igst + previous.cess > 0;
    if (!firm.isGstRegistered && !historicalTax) {
      draft = draft.copyWith(
        lines: draft.lines
            .map(
              (l) => SalesLineDraft(
                id: l.id,
                itemId: l.itemId,
                name: l.name,
                hsn: l.hsn,
                quantity: l.quantity,
                unit: l.unit,
                rate: l.rate,
                discountPercent: l.discountPercent,
                discountAmount: l.discountAmount,
                gstRate: 0,
                cessRate: 0,
                taxMode: TaxMode.exclusive,
              ),
            )
            .toList(),
        reverseCharge: false,
      );
    }
    // A negative amount is never a real document.
    //
    // `Money.tryParse` accepts a leading `-`, so a pasted "-100" produced
    // `grandTotal: -118.00`, and `DocumentSettlement.of` then clamped the
    // balance to 0 and reported the document as **paid**. A negative invoice was
    // written to the books and read as settled, which is the worst of both.
    // Rejecting it here is the backstop; the editors also validate the Rate
    // cell, so this is the layer that cannot be bypassed by an import, a
    // deep link or a future caller.
    if (draft.lines.any(
      (l) => l.rate < Decimal.zero || l.quantity < Decimal.zero,
    )) {
      throw ArgumentError(
        'A document cannot be saved with a negative rate or quantity.',
      );
    }
    // The caller resolves the split from the firm's state vs the place of
    // supply; [isInterState] is the stored denormalized flag.
    // Exports are always inter-state under IGST Act s.7(5), and an export
    // without payment of tax (LUT/Bond, 'wop') is zero-rated with no GST.
    final isExportWop =
        draft.isExport &&
        (draft.exportType ?? '').trim().toLowerCase() == 'wop';
    final effectiveLines = isExportWop
        ? draft.lines
              .map(
                (l) => SalesLineDraft(
                  id: l.id,
                  itemId: l.itemId,
                  name: l.name,
                  hsn: l.hsn,
                  quantity: l.quantity,
                  unit: l.unit,
                  rate: l.rate,
                  discountPercent: l.discountPercent,
                  discountAmount: l.discountAmount,
                  gstRate: 0,
                  cessRate: 0,
                  taxMode: TaxMode.exclusive,
                ),
              )
              .toList()
        : draft.lines;
    final split = (draft.isInterState || draft.isExport)
        ? GstSplit.interState
        : GstSplit.intraState;
    final result = GstEngine.computeDocument(
      lines: effectiveLines.map((l) => l.toTaxLine()).toList(),
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
    final grandTotal = result.grandTotal + draft.shippingChargeValue + tcs;
    // **Negative, not zero.** A ₹0 document is not corrupt — a draft saved
    // before its lines are typed, a fully-discounted give-away, a quotation
    // being built — and refusing it would break real flows. A *negative* one is
    // always a data error, and it was the dangerous case: `DocumentSettlement`
    // clamped it to a zero balance and reported the document as `paid`, so a
    // negative invoice sat in the books reading as settled.
    if (grandTotal < Decimal.zero) {
      throw ArgumentError(
        'A document cannot be worth a negative amount — check the rate and '
        'discount on each line.',
      );
    }
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
        for (final old in await itemsFor(draft.id)) {
          if (!draft.lines.any((line) => line.id == old.id)) {
            await enqueue(
              firmId: firmId,
              entity: 'sales_invoice_items',
              entityId: old.id,
              operation: 'delete',
            );
          }
        }
        await db.reverseStockForSource(firmId, draft.id);
        await (db.delete(
          db.salesInvoiceItems,
        )..where((t) => t.invoiceId.equals(draft.id))).go();
      }

      // Payments already recorded against this id must survive the re-save;
      // balanceDue and paymentStatus are derived from them, not reset.
      final paidAmount = existing?.paidAmount ?? 0.0;
      // One derivation, one truth (see [DocumentSettlement]). Only an invoice
      // is payable; every other document type stores a zero balance — and now
      // a status that agrees with it.
      final settlement = draft.docType == 'invoice'
          ? DocumentSettlement.of(
              grandTotal: grandTotal.toDouble(),
              paidAmount: paidAmount,
            )
          : DocumentSettlement.settled;

      final companion = SalesInvoicesCompanion.insert(
        id: draft.id,
        firmId: firmId,
        docType: Value(draft.docType),
        number: draft.number,
        partyId: Value(draft.partyId),
        invoiceDate: draft.invoiceDate,
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
        shippingAddress: Value(draft.shippingAddress),
        placeOfSupply: Value(draft.placeOfSupply),
        isInterState: Value(draft.isInterState || draft.isExport),
        reverseCharge: Value(draft.reverseCharge),
        isExport: Value(draft.isExport),
        exportType: Value(draft.isExport ? (draft.exportType ?? 'wp') : null),
        subTotal: Value(result.subTotal.toDouble()),
        itemDiscount: Value(result.itemDiscountTotal.toDouble()),
        invoiceDiscountPercent: Value(
          draft.invoiceDiscountPercentValue.toDouble(),
        ),
        invoiceDiscountAmount: Value(
          draft.invoiceDiscountAmountValue.toDouble(),
        ),
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
        await db
            .into(db.salesInvoiceItems)
            .insert(
              draft.lines[i].toCompanion(
                draft.id,
                i,
                result.lineFor(draft.lines[i].id),
              ),
            );
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
      const stocklessDocTypes = {'quotation', 'sales_order', 'delivery_note'};
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
            // A credit note puts stock *back*, and at what cost? At the cost it
            // left at — which the writer derives from the running average, so
            // nothing is passed. Passing a value here would value returned goods
            // at today's cost and make the return's margin wrong.
            sourceLineId: line.id,
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

  /// "Invoice INV-4" — how a refusal names the row it refused, so the message
  /// a user reads names a document rather than a uuid.
  String _docLabel(SalesInvoiceEntity doc) => 'Document ${doc.number}';

  /// The live (not-recycled) document, for edit/save paths. Re-saving a
  /// binned document used to silently resurrect it, rewrite its lines and
  /// re-post its stock — the editor must load through this.
  Future<SalesInvoiceEntity?> getLiveById(String id) async {
    final query = db.select(db.salesInvoices)
      ..where(
        (t) =>
            t.id.equals(id) &
            t.firmId.equals(firmId) &
            t.isDeleted.equals(false),
      );
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
          .map(
            (l) => SalesLineDraft(
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
            ),
          )
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
      invoiceDiscountPercent: Decimal.parse(
        doc.invoiceDiscountPercent.toString(),
      ),
      invoiceDiscountAmount: Decimal.parse(
        doc.invoiceDiscountAmount.toString(),
      ),
      shippingCharge: Decimal.parse(doc.shippingCharge.toString()),
      applyRoundOff:
          doc.roundOff.abs() > 0.000001 ||
          (doc.grandTotal - doc.grandTotal.round()).abs() < 0.001,
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
      ..where(
        (t) =>
            t.firmId.equals(firmId) &
            t.docType.equals(docType) &
            t.isDeleted.equals(false),
      )
      ..orderBy([
        (t) => OrderingTerm.desc(t.invoiceDate),
        (t) => OrderingTerm(expression: t.number),
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
      query.where(
        (t) => t.number.lower().like(s) | t.partyName.lower().like(s),
      );
    }
    query.limit(limit);
    return query.get();
  }

  /// Unpaid invoices **past their due date**, most overdue first — the payment
  /// reminders list. Any not-cancelled, not-binned document with a balance
  /// counts (a 'delivered' invoice is just as overdue as a 'confirmed' one).
  Stream<List<SalesInvoiceEntity>> watchOverdue({int limit = 500}) {
    // **Past their due date**, which the query used not to require. The default
    // credit term is 15 days, so on the 1st of the month every invoice raised
    // that month — with a due date still in the future — appeared under a
    // heading reading "N overdue invoice". The row's own `_daysLate` was then
    // negative and printed the literal "-9d late", while the empty state said
    // "every invoice is paid or still within its due date", contradicted by the
    // list above it. `sales_list_screen` has always filtered correctly here.
    final now = DateTime.now();
    final query = db.select(db.salesInvoices)
      ..where(
        (t) =>
            t.firmId.equals(firmId) &
            t.docType.equals('invoice') &
            t.isDeleted.equals(false) &
            t.status.equals('cancelled').not() &
            t.status.equals('converted').not() &
            t.balanceDue.isBiggerThanValue(0.001) &
            t.dueDate.isNotNull() &
            t.dueDate.isSmallerThanValue(now),
      )
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
    Set<DocumentStatus> statuses = const {},
  }) {
    // A converted document is one of two things on disk: pre-v9 rows carry
    // status 'converted', post-v9 rows keep their lifecycle and point at the
    // invoice via convertedToInvoiceId. Both mean the same thing to the
    // operator, so the filter has to accept both — matching the status column
    // alone would make the filter silently miss every document converted
    // since the upgrade, which is every document a new user has.
    const storedStatuses = {
      DocumentStatus.draft,
      DocumentStatus.confirmed,
      DocumentStatus.delivered,
      DocumentStatus.sent,
      DocumentStatus.accepted,
      DocumentStatus.rejected,
      DocumentStatus.cancelled,
    };
    final byStored = statuses.where(storedStatuses.contains).toSet();
    final wantsConverted = statuses.contains(DocumentStatus.convertedLegacy);
    final wantsExpired = statuses.contains(DocumentStatus.expired);

    final query = db.select(db.salesInvoices)
      ..where(
        (t) =>
            t.firmId.equals(firmId) &
            t.docType.equals(docType) &
            t.isDeleted.equals(false),
      )
      ..orderBy([
        (t) => OrderingTerm.desc(t.invoiceDate),
        (t) => OrderingTerm(expression: t.number),
      ]);
    if (byStored.isNotEmpty || wantsConverted) {
      query.where(
        (t) => [
          if (byStored.isNotEmpty) t.status.isIn(byStored.map((s) => s.name)),
          if (wantsConverted)
            t.convertedToInvoiceId.isNotNull() | t.status.equals('converted'),
        ].reduce((a, b) => a | b),
      );
    }
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
      query.where(
        (t) => t.number.lower().like(s) | t.partyName.lower().like(s),
      );
    }
    query.limit(limit);
    final stream = query.watch();
    if (!wantsExpired) return stream;

    // Expired is derived from the valid-till date, not stored, so it cannot be
    // part of the SQL WHERE — SQLite has no idea which documents it applies to.
    // Filtering after the query is exact but caps at [limit] *before* the
    // filter, so "Expired" on a month with 200 invoices could return fewer
    // than the limit even when more expired rows exist below it. Accepted,
    // because a filter that under-reports silently is worse than one that
    // pages; the list already tells the operator how many rows are loaded.
    return stream.map(
      (rows) => rows
          .where(
            (d) => DocumentStatus.isExpired(
              status: d.status,
              docType: d.docType,
              validTill: d.dueDate,
            ),
          )
          .toList(growable: false),
    );
  }

  /// Every non-deleted sales document (invoices, quotations, orders, notes)
  /// for one party, newest first — the Parties master-detail's right pane.
  Stream<List<SalesInvoiceEntity>> watchForParty(
    String partyId, {
    int limit = 500,
  }) {
    final query = db.select(db.salesInvoices)
      ..where(
        (t) =>
            t.firmId.equals(firmId) &
            t.partyId.equals(partyId) &
            t.isDeleted.equals(false),
      )
      ..orderBy([
        (t) => OrderingTerm.desc(t.invoiceDate),
        (t) => OrderingTerm(expression: t.number),
      ])
      ..limit(limit);
    return query.watch();
  }

  Future<void> markCancelled(String id, {String? actor}) async {
    db.assertPermission(Permission.cancelDocument);
    await db.transaction(() async {
      final doc = await getById(id);
      if (doc == null) return;
      // A pre-v9 converted row cannot be un-converted: its flag lives in
      // `status`, which this write overwrites, and the invoice it became was
      // never recorded. Cancelling one would wipe the flag and leave a
      // quotation that had genuinely been invoiced looking convertible again.
      // Refusing is the lesser wrong — the document is already invoiced, so
      // there is nothing about it left to withdraw.
      if (doc.status == DocumentStatus.legacyConvertedValue) {
        throw StateError(
          'This ${doc.docType} was already converted to an invoice. Cancel '
          'the invoice instead — cancelling the ${doc.docType} cannot recall '
          'the invoice it produced.',
        );
      }
      await db.assertDateEditable(firmId, doc.invoiceDate);
      // A cancelled invoice stops chasing money: its balance columns zero
      // out so outstanding/ageing never count it (H3 parity at the row level).
      // The status comes from the same derivation as everywhere else, so the
      // row cannot end up reading "Unpaid" beside a zero balance.
      await db
          .update(db.salesInvoices)
          .replace(
            doc.copyWith(
              status: 'cancelled',
              balanceDue: DocumentSettlement.settled.balance,
              paidAmount: doc.paidAmount,
              paymentStatus: DocumentSettlement.settled.status,
              updatedAt: DateTime.now(),
            ),
          );
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
  /// locked period, and refused when the document is already in the bin —
  /// reversing an already-reversed document silently doubled its stock back.
  ///
  /// Returns whether it actually did anything, and **false** for an id that is
  /// not in the books. That used to be a bare `return`, which was correct for a
  /// single delete (nothing to do) and silently wrong for a bulk one: the
  /// caller was told it had deleted a document that was never there, and would
  /// then offer an undo covering it. Statement call sites are unaffected.
  Future<bool> softDelete(String id, {String? actor}) async {
    // Checked before the transaction, not inside it. The session is in-memory,
    // so a refusal has nothing to read and nothing to roll back — opening a
    // transaction to throw out of it is wasted work and a stack of frames that
    // says the write was attempted when it was refused.
    db.assertPermission(Permission.softDelete);
    var deleted = false;
    await db.transaction(() async {
      final doc = await getById(id);
      if (doc == null) return;
      if (doc.isDeleted) {
        throw StateError('${_docLabel(doc)} is already in the recycle bin.');
      }
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
        firmId: firmId,
        entity: 'sales_invoices',
        entityId: id,
        operation: 'delete',
      );
      await db.auditRepository.log(
        action: 'delete',
        entity: 'sales_invoices',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary:
            'Deleted ${doc.docType} ${doc.number}'
            ' for ${doc.partyName ?? "walk-in"}',
      );
      deleted = true;
    });
    return deleted;
  }

  /// Restores a soft-deleted document and re-applies its stock effect. Refused
  /// for a document that is not in the bin — re-posting a live document's
  /// stock deducted it a second time, and the guard used to live only in the
  /// UI that hides the action.
  Future<bool> restore(String id, {String? actor}) async {
    db.assertPermission(Permission.softDelete);
    var restored = false;
    await db.transaction(() async {
      final doc = await getById(id);
      if (doc == null) return;
      if (!doc.isDeleted) {
        throw StateError(
          '${_docLabel(doc)} is not in the recycle bin — there is nothing '
          'to restore.',
        );
      }
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
        firmId: firmId,
        entity: 'sales_invoices',
        entityId: id,
        operation: 'update',
      );
      await db.auditRepository.log(
        action: 'restore',
        entity: 'sales_invoices',
        firmId: firmId,
        actor: actor,
        entityId: id,
        summary: 'Restored ${doc.docType} ${doc.number}',
      );
      restored = true;
    });
    return restored;
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
    db.assertPermission(Permission.purge);
    await db.transaction(() async {
      final doc = await getById(id);
      if (doc == null) return;
      if (!doc.isDeleted) {
        throw StateError(
          'Move this document to the recycle bin before deleting it '
          'permanently.',
        );
      }
      await db.assertDateEditable(firmId, doc.invoiceDate);
      await (db.delete(
        db.salesInvoiceItems,
      )..where((t) => t.invoiceId.equals(id))).go();
      await (db.delete(
        db.salesInvoices,
      )..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).go();
      await enqueue(
        firmId: firmId,
        entity: 'sales_invoices',
        entityId: id,
        operation: 'delete',
      );
      await db.auditRepository.log(
        action: 'purge',
        entity: 'sales_invoices',
        firmId: firmId,
        entityId: id,
        summary: 'Permanently deleted ${doc.docType} ${doc.number}',
      );
    });
  }

  /// Records that [id] became [invoiceId].
  ///
  /// Writes the link and the timestamp; deliberately leaves `status` alone.
  /// It used to overwrite it with 'converted', which destroyed the document's
  /// actual lifecycle — a quotation that had been sent became indistinguishable
  /// from one that had been cancelled, and `markCancelled` on it silently
  /// un-converted it. Conversion is an event, and an event is a link, not a
  /// replacement state.
  ///
  /// Guards: refuses a document already converted, and refuses dates inside a
  /// locked period. The first is what makes a stale double-tap harmless — the
  /// UI hides the action, but a second tap can land before the rebuild.
  /// Create the invoice and consume its source atomically, including stock and
  /// sync outbox writes. An editor opened before another conversion cannot
  /// create a second invoice from the same estimate.
  Future<SalesInvoiceEntity> convertToInvoice(
    SalesDraft draft, {
    required String sourceId,
    bool affectStock = true,
  }) => db.transaction(() async {
    final source = await getLiveById(sourceId);
    if (source == null ||
        draft.docType != 'invoice' ||
        ![
          'quotation',
          'sales_order',
          'delivery_note',
        ].contains(source.docType) ||
        source.convertedToInvoiceId != null ||
        [
          'converted',
          'cancelled',
          'rejected',
          'expired',
        ].contains(source.status)) {
      throw StateError(
        'This document cannot be converted again. Open its linked invoice or refresh the list.',
      );
    }
    final invoice = await save(draft, affectStock: affectStock);
    await markConverted(sourceId, invoiceId: invoice.id);
    return invoice;
  });

  Future<void> markConverted(
    String id, {
    required String invoiceId,
    String? actor,
  }) async {
    db.assertPermission(Permission.createSales);
    await db.transaction(() async {
      final doc = await getById(id);
      if (doc == null) return;
      if (doc.convertedToInvoiceId != null) return;
      await db.assertDateEditable(firmId, doc.invoiceDate);
      await db
          .update(db.salesInvoices)
          .replace(
            doc.copyWith(
              convertedToInvoiceId: Value(invoiceId),
              convertedAt: Value(DateTime.now()),
              updatedAt: DateTime.now(),
            ),
          );
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
        summary: 'Converted ${doc.docType} ${doc.number} to invoice $invoiceId',
      );
    });
  }

  /// Moves a document to a new lifecycle state.
  ///
  /// A repository method rather than a generic setter, because each write has
  /// its own rules and a setter is where those rules get forgotten: the target
  /// is checked against [DocumentStatus.transitionsFrom], so "cancel an
  /// accepted quotation" cannot happen by calling this with the wrong argument
  /// from a screen nobody reviewed.
  ///
  /// Refuses dates inside a locked period, like every other status write.
  Future<void> markStatus(
    String id,
    DocumentStatus status, {
    String? actor,
  }) async {
    // Answering a quotation is a statement to a customer, so it is a
    // cancel-class action rather than a save.
    db.assertPermission(
      status == DocumentStatus.cancelled
          ? Permission.cancelDocument
          : Permission.createSales,
    );
    await db.transaction(() async {
      final doc = await getById(id);
      if (doc == null) return;
      await db.assertDateEditable(firmId, doc.invoiceDate);
      // Expired is derived from the valid-till date, so it is not a state a
      // caller may write — it would disagree with the column that computes it
      // the moment the date moved.
      if (status == DocumentStatus.expired) {
        throw ArgumentError(
          'Expired is derived from the valid-till date, not stored. '
          'Withdrawing or reissuing is what an operator does with a lapsed '
          'quotation.',
        );
      }
      final from = DocumentStatus.of(doc.status, doc.docType);
      if (!from.transitionsFrom(from, doc.docType).contains(status)) {
        throw StateError(
          'A ${doc.docType} that is "${from.label}" cannot become '
          '"${status.label}".',
        );
      }
      await db
          .update(db.salesInvoices)
          .replace(
            doc.copyWith(status: status.name, updatedAt: DateTime.now()),
          );
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
        summary: 'Marked ${doc.docType} ${doc.number} as ${status.label}',
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
          'document.',
        );
      }
      await db.assertDateEditable(firmId, date ?? doc.invoiceDate);
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
          .update(db.salesInvoices)
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
    final docs = await list(
      docType: 'invoice',
      from: from,
      to: to,
      limit: 100000,
    );
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
    DateTime date, {
    String? sourceLineId,
    Decimal? unitCost,
  }) async {
    final item =
        await (select(items)
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
      item.copyWith(currentStock: newBalance, updatedAt: DateTime.now()),
    );
    // What the movement was worth, decided once, and decided by **kind** rather
    // than by the sign of the quantity.
    //
    // Routing on the sign was wrong for `sale_return`. A credit note puts stock
    // *back*, so its movement is inbound (`quantity > 0`), and inbound took
    // `unitCost ?? item.purchasePrice` — but the credit-note writer deliberately
    // passes no cost, precisely because "at what cost did it leave?" is the
    // moving average. So a return of 3 units against a 10-unit sale was stamped
    // at the *catalogue* purchase price, which nothing maintains and which is
    // therefore 0 for most shops: the average collapsed by 30% and every later
    // sale booked an inflated margin.
    //
    // The three cases are genuinely different and now say so:
    //  * a reversal      — copy the movement it undoes (the caller stamps it)
    //  * a sale return   — the average at this instant, exactly like a sale
    //  * anything else   — the caller's cost, else the catalogue price
    final isReversal = source == 'reversal';
    final stamped = isReversal
        ? (unitCost ?? Money.of(item.purchasePrice))
        : (kind == 'sale_return' || quantity < 0)
        ? await _averageCostAt(firmId, itemId, date) ??
              Money.of(item.purchasePrice)
        : (unitCost ?? Money.of(item.purchasePrice));
    final movementId = newStockMovementId();
    await into(stockMovements).insert(
      StockMovementsCompanion.insert(
        id: movementId,
        firmId: firmId,
        itemId: itemId,
        kind: kind,
        quantity: quantity,
        balanceAfter: Value(newBalance),
        unitCost: Value(stamped.toDouble()),
        source: source,
        sourceId: Value(sourceId),
        sourceLineId: Value(sourceLineId),
        sourceNumber: Value(sourceNumber),
        date: date,
      ),
    );

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
  ///
  /// Two rules keep the ledger from growing on every cycle:
  ///
  /// 1. **Reversal rows are never reversed again.** They carry the same
  ///    `sourceId` as the movement they undo, so the query used to match them
  ///    too and post the opposite of each — net stock stayed right while the
  ///    table doubled per call (2^n phantom rows for one document after n
  ///    edit/delete cycles), in the table the code itself calls "the stock
  ///    ledger of record".
  /// 2. **A movement is reversed at most once**, enforced by
  ///    [_stockReversalId] (see above). Without it, skipping rule 1 alone
  ///    would still leave one orphan reversal per call.
  ///
  /// Migration: the `notes = 'reversal'` marker has been written since the
  /// reversal path was introduced, so existing rows are recognised by rule 1
  /// and stay excluded — the doubling stops immediately. Rows written by the
  /// *old* code carry random ids, so they cannot be paired with the movement
  /// they undo after the fact; they are left in place (they net to zero
  /// against their originals, so deleting them would double the reversal)
  /// and only stop multiplying. A firm that wants a clean ledger purges the
  /// affected documents, which is the one operation that rewrites it.
  /// The moving-average cost of [itemId] as at [moment], or null when it is
  /// undefined (an item that has never been bought).
  ///
  /// Replays the item's whole log rather than reading a cached running average:
  /// the cache would be one document edit, conversion or soft-delete away from
  /// being wrong, and a wrong cost here is a wrong margin in every report
  /// built on it.
  ///
  /// Ordered by `date, id` — the id is a monotonic counter, so two movements
  /// written in the same microsecond still have a defined order, and the
  /// average depends on which came first.
  Future<Decimal?> _averageCostAt(
    String firmId,
    String itemId,
    DateTime moment,
  ) async {
    final rows =
        await (select(stockMovements)
              ..where((t) => t.firmId.equals(firmId) & t.itemId.equals(itemId))
              ..orderBy([
                (t) => OrderingTerm.asc(t.date),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();

    var costing = MovingAverageCosting.initial();
    for (final row in rows) {
      // Everything at or before `moment` is history. A row sharing the exact
      // timestamp counts — the new movement is appended behind it.
      if (row.date.isAfter(moment)) break;
      final (next, _) = costing.apply(
        CostedMovement(
          id: row.id,
          kind: row.kind,
          quantity: row.quantity,
          unitCost: Money.of(row.unitCost),
        ),
      );
      costing = next;
    }
    return costing.average;
  }

  /// Posts the equal-and-opposite of every movement [sourceId] recorded, so a
  /// document being rewritten lands at the net effect of its new lines rather
  /// than its old lines plus its new ones.
  ///
  /// Two rules keep the ledger from growing on every cycle:
  ///
  /// 1. **Reversal rows are never reversed again.** They carry the same
  ///    `sourceId` as the movement they undo, so the query used to match them
  ///    too and post the opposite of each — net stock stayed right while the
  ///    table doubled per call (2^n phantom rows for one document after n
  ///    edit/delete cycles), in the table the code itself calls "the stock
  ///    ledger of record".
  /// 2. **A movement is reversed at most once**, enforced by
  ///    [_stockReversalId] (see above). Without it, skipping rule 1 alone
  ///    would still leave one orphan reversal per call.
  ///
  /// Migration: the `notes = 'reversal'` marker has been written since the
  /// reversal path was introduced, so existing rows are recognised by rule 1
  /// and stay excluded — the doubling stops immediately. Rows written by the
  /// *old* code carry random ids, so they cannot be paired with the movement
  /// they undo after the fact; they are left in place (they net to zero
  /// against their originals, so deleting them would double the reversal)
  /// and only stop multiplying. A firm that wants a clean ledger purges the
  /// affected documents, which is the one operation that rewrites it.
  Future<void> reverseStockForSource(String firmId, String sourceId) async {
    final movements =
        await (select(stockMovements)..where(
              (t) =>
                  t.firmId.equals(firmId) &
                  t.sourceId.equals(sourceId) &
                  // `IS NOT` rather than `<>`: SQL three-valued logic would make
                  // `notes <> 'reversal'` FALSE for every row whose notes are NULL,
                  // which is most of them.
                  t.notes.isNotValue(_kStockReversalNote),
            ))
            .get();
    for (final m in movements) {
      // Already undone — see rule 2 above.
      final reversalId = _stockReversalId(m.id);
      final posted = await (select(
        stockMovements,
      )..where((t) => t.id.equals(reversalId))).getSingleOrNull();
      if (posted != null) continue;

      final item =
          await (select(items)
                ..where((t) => t.id.equals(m.itemId) & t.firmId.equals(firmId)))
              .getSingleOrNull();
      if (item == null) continue;
      final newBalance = item.currentStock - m.quantity;
      await update(items).replace(
        item.copyWith(currentStock: newBalance, updatedAt: DateTime.now()),
      );
      await into(stockMovements).insert(
        StockMovementsCompanion.insert(
          id: reversalId,
          firmId: firmId,
          itemId: m.itemId,
          kind: m.kind,
          quantity: -m.quantity,
          balanceAfter: Value(newBalance),
          // The reversal undoes a movement at the cost *that* movement was
          // recorded at, not at today's average. Re-valuing it here would make
          // the pair asymmetric — the original removed value at one price and
          // the reversal put it back at another — so the two would never net
          // to zero, and every edit would leak cost into the valuation.
          unitCost: Value(m.unitCost),
          source: m.source,
          sourceId: Value(sourceId),
          sourceLineId: Value(m.sourceLineId),
          godownId: Value(m.godownId),
          sourceNumber: Value(m.sourceNumber),
          // Reversals are bookkeeping events, not transactions: date them at
          // the original movement's date so the ledger stays chronologically
          // consistent with the document that produced it.
          date: m.date,
          notes: const Value(_kStockReversalNote),
        ),
      );
      await _MovementOutbox(this).enqueue(
        firmId: firmId,
        entity: 'stock_movements',
        entityId: reversalId,
        operation: 'insert',
      );
    }
  }
}

/// Marks a row posted by [StockMovementsInsert.reverseStockForSource]. A
/// reversal carries the source document's own `sourceId`, so this note is the
/// only thing separating "the document moved this stock" from "we undid that".
const String _kStockReversalNote = 'reversal';

/// The id of the reversal owed by the movement [movementId].
///
/// Idempotency: a document is rewritten many times, and each call has to undo
/// exactly the movements still standing. Keying the reversal on the movement it
/// undoes turns "already reversed" into a lookup — `rev_<movement id>` either
/// exists or it does not — instead of a heuristic, so a repeated call (a
/// double-tap, a retried sync pull that already carries the row) can never post
/// the opposite twice.
String _stockReversalId(String movementId) => 'rev_$movementId';

/// Outbox access for [StockMovementsInsert], which is an extension on the
/// database and has no repository of its own to inherit the sync mixin.
class _MovementOutbox with SyncQueueMixin {
  _MovementOutbox(this.db);

  @override
  final AppDatabase db;
}
