import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../constants/indian_states.dart';
import '../database/app_database.dart';
import '../database/repositories/firm_repository.dart';
import '../database/repositories/party_repository.dart';
import '../database/repositories/purchase_repository.dart';
import '../database/repositories/repository_extensions.dart';
import '../database/repositories/sales_repository.dart';
import '../utils/id_utils.dart';
import '../utils/money.dart';
import '../database/repositories/sync_mixin.dart';
import 'vyapar_backup.dart';

// Callers should not have to reach past this file to catch a bad backup.
export 'vyapar_backup.dart' show VyaparFormatException;

/// Imports a Vyapar `.vyb` backup into Apex Books.
///
/// Vyapar's backup *is* its SQLite database, so this is a real migration rather
/// than a spreadsheet import: parties, items, GST rates, stock, sales,
/// purchases and the money received against them all come across, and the books
/// are made to agree with the numbers Vyapar was showing.
///
/// ## Document types
///
/// | Vyapar (`kb_transactions.txn_type`) | Apex Books `docType` |
/// | --- | --- |
/// | 1 sale invoice | `invoice` |
/// | 24 sale order | `sales_order` |
/// | 27 estimate / quotation | `quotation` |
/// | 83 proforma invoice | `quotation` |
/// | 30 delivery challan | `delivery_note` |
/// | 2 purchase bill | `bill` |
/// | 28 purchase order | `purchase_order` |
/// | 3 payment in, 4 payment out | `payments` |
/// | `journal_entry` (an expense head against cash/bank) | `expenses` |
///
/// Anything else is counted and reported instead of guessed at. Vyapar's own
/// seed data (`terms_and_conditions` joined to `tnc_txn_type_mapping`) is what
/// pins these codes down — in particular `28` is a purchase *order*, not a bill.
///
/// ## The rules that make the numbers add up
///
/// * **Document numbers are kept.** A Vyapar invoice numbered `19` stays `19`;
///   only real collisions inside one series get a `-2` suffix.
/// * **Line rates are GST-exclusive.** `kb_lineitems.priceperunit` is the
///   taxable rate even where `txn_tax_inclusive` is set, so Apex Books's GST engine
///   reproduces Vyapar's line totals rather than inflating them.
/// * **Balances come from Vyapar.** Each document's outstanding is
///   `txn_balance_amount` less the payments Vyapar recorded as transactions of
///   their own, so the ageing report matches what the user was looking at.
/// * **Stock is reconciled, not double-counted.** An item's opening stock is
///   Vyapar's *current* stock minus the net effect of the invoices and bills
///   being imported, so closing stock lands exactly on Vyapar's figure.
/// * **Opening balances absorb the remainder.** A party balance is Vyapar's
///   balance minus what the imported documents explain, which keeps money owed
///   correct even when the backup holds documents Apex Books does not import.
///
/// The write is not one transaction — each repository opens its own — so failure
/// is handled by deleting everything created for the new firm and rethrowing.
/// The caller never sees a half-imported firm.
class VyaparImportService {
  VyaparImportService(this.db);

  final AppDatabase db;

  /// Reads the backup without touching the database, so the user can be shown
  /// what is about to happen before anything is written.
  Future<VyaparImportPreview> preview(Uint8List bytes) async {
    final snapshot = await VyaparBackupReader.read(bytes);
    return VyaparImportPreview(
      firmName: _firmName(snapshot),
      gstin: cleanString(snapshot.firm['firm_gstin_number']),
      state: cleanString(snapshot.firm['firm_state']),
      from: _earliestDocumentDate(snapshot),
      to: _latestDocumentDate(snapshot),
      counts: countSnapshot(snapshot),
      warnings: _snapshotWarnings(snapshot),
    );
  }

  /// Imports the backup into a brand new firm and returns what was written.
  Future<VyaparImportResult> run(Uint8List bytes) async {
    final snapshot = await VyaparBackupReader.read(bytes);
    final run = _ImportRun(db, snapshot);

    final firm = await run.createFirm();
    try {
      await run.execute(firm);
    } on Object {
      await _deleteFirmData(firm.id);
      rethrow;
    }

    await db.settingsSet('active_firm_id', firm.id);
    return VyaparImportResult(
      firmId: firm.id,
      firmName: firm.name,
      counts: run.counts.freeze(),
      warnings: run.warnings,
    );
  }

  /// Removes every row created for [firmId].
  ///
  /// Delegates to [eraseFirmRows], which Settings' "remove this business" also
  /// uses. There used to be a second copy of this list here, and a second copy
  /// is exactly how a table added later gets erased on one path and forgotten
  /// on the other.
  Future<void> _deleteFirmData(String firmId) => eraseFirmRows(db, firmId);

  // ---- Snapshot-only helpers --------------------------------------------

  static String _firmName(VyaparSnapshot snapshot) =>
      cleanString(snapshot.firm['firm_name']) ?? 'Vyapar company';

  static DateTime? _earliestDocumentDate(VyaparSnapshot snapshot) {
    DateTime? earliest;
    for (final document in snapshot.documents) {
      final date = document.date;
      if (date == null) continue;
      if (earliest == null || date.isBefore(earliest)) earliest = date;
    }
    return earliest;
  }

  static DateTime? _latestDocumentDate(VyaparSnapshot snapshot) {
    DateTime? latest;
    for (final document in snapshot.documents) {
      final date = document.date;
      if (date == null) continue;
      if (latest == null || date.isAfter(latest)) latest = date;
    }
    return latest;
  }

  /// Counts what a run would write, without writing it.
  static VyaparImportCounts countSnapshot(VyaparSnapshot snapshot) {
    final counts = _MutableCounts()
      ..parties = snapshot.parties.length
      ..items = snapshot.items.length
      ..categories =
          snapshot.itemCategories.length + snapshot.expenseHeads.length
      ..expenses = snapshot.expenses.length;
    for (final document in snapshot.documents) {
      switch (document.kind) {
        case VyaparDocKind.saleInvoice:
          counts.saleInvoices++;
        case VyaparDocKind.quotation:
          counts.quotations++;
        case VyaparDocKind.saleOrder:
          counts.saleOrders++;
        case VyaparDocKind.deliveryNote:
          counts.deliveryNotes++;
        case VyaparDocKind.purchaseBill:
          counts.purchaseBills++;
        case VyaparDocKind.purchaseOrder:
          counts.purchaseOrders++;
        case VyaparDocKind.paymentIn:
        case VyaparDocKind.paymentOut:
          counts.payments++;
        case VyaparDocKind.unsupported:
          counts.skipped++;
      }
    }
    final paymentTransactions = {
      for (final document in snapshot.documents)
        if (document.kind == VyaparDocKind.paymentIn ||
            document.kind == VyaparDocKind.paymentOut)
          document.id,
    };
    for (final split in snapshot.paymentSplits) {
      if (split.amount > 0 &&
          !paymentTransactions.contains(split.documentTxnId)) {
        counts.payments++;
      }
    }
    return counts.freeze();
  }

  static List<String> _snapshotWarnings(VyaparSnapshot snapshot) {
    final warnings = [...snapshot.warnings];

    final unsupported = snapshot.unsupportedTypeCounts;
    if (unsupported.isNotEmpty) {
      final total = unsupported.values.fold(0, (a, b) => a + b);
      final codes = unsupported.keys.toList()..sort();
      warnings.add(
        '$total transaction(s) use a Vyapar document type Apex Books does not '
        'import yet (type code ${codes.join(', ')}), so they were left behind '
        'rather than guessed at.',
      );
    }

    var cessLines = 0;
    for (final lines in snapshot.linesByTxn.values) {
      for (final line in lines) {
        if (line.cess != 0) cessLines++;
      }
    }
    if (cessLines > 0) {
      warnings.add(
        'Additional cess is stored per unit in Vyapar and as a percentage in '
        'Apex Books, so $cessLines line(s) came across without cess.',
      );
    }

    if (snapshot.partyGroups.isNotEmpty) {
      warnings.add(
        'Party groups were not imported — Apex Books separates parties by type '
        '(customer, supplier) instead.',
      );
    }
    return warnings;
  }
}

/// One run of the importer: holds the id mappings and the running totals that
/// the phases share, so no phase has to re-read what an earlier one wrote.
class _ImportRun with SyncQueueMixin {
  _ImportRun(this.db, this.snapshot);

  @override
  final AppDatabase db;
  final VyaparSnapshot snapshot;

  final _MutableCounts counts = _MutableCounts();
  final List<String> warnings = [];

  late FirmEntity firm;

  /// Vyapar id → Apex Books id.
  final Map<int, String> partyIds = {};
  final Map<int, String> itemIds = {};
  final Map<int, String> unitIds = {};
  final Map<int, String> categoryIds = {};

  /// Derived per item, reused for every line that references it.
  final Map<int, double> itemGstRate = {};
  final Map<int, String> itemUnit = {};
  final Map<int, String> itemName = {};
  final Map<int, String?> itemHsn = {};
  final Map<int, String> partyName = {};

  /// Vyapar transaction id → what it became in Apex Books.
  final Map<int, VyaparDocKind> importedKinds = {};
  final Map<int, String> documentIds = {};
  final Map<int, String> paymentAccountIds = {};
  final Map<int, double> documentTotals = {};

  /// Vyapar transaction id → money already recorded against it, so the
  /// payment-split rows only ever contribute the remainder.
  ///
  /// Kept apart from [settledByPaymentTxn] on purpose: Vyapar's
  /// `txn_balance_amount` already nets out the payments recorded in
  /// `txn_payment_mapping`, so only standalone payment *transactions*
  /// (`kb_txn_links`) may be subtracted from it again. Verified across a real
  /// backup, where `balance = lineTotals - mappedPayments` on all 27 invoices.
  final Map<int, double> settledByPaymentTxn = {};
  final Map<int, double> paidBySplit = {};

  final Map<String, Set<String>> usedNumbers = {};

  /// Set once a malformed GSTIN has been left behind, so the warning is written
  /// once instead of once per party.
  bool _warnedAboutGstin = false;

  /// Whether the Vyapar company itself was GST registered, resolved in
  /// [execute] once the firm row exists.
  bool companyIsGstRegistered = false;

  /// Documents with no lines, empty firm details and the like, reported once.
  final List<String> _pendingWarnings = [];

  // ---- Entry point -------------------------------------------------------

  Future<void> execute(FirmEntity newFirm) async {
    firm = newFirm;
    warnings
      ..clear()
      ..addAll(VyaparImportService._snapshotWarnings(snapshot));

    companyIsGstRegistered = _resolveCompanyGstRegistration();
    if (!companyIsGstRegistered) {
      warnings.add(
        'This Vyapar company is not registered for GST, so no inter-state IGST '
        'will be applied and the GST returns will not apply to it. Any tax '
        'Vyapar recorded on its documents was kept as it was.',
      );
    }

    _indexLookups();

    await _importUnits();
    await _importCategories();
    await _importParties();
    await _importItems();
    await _importAccounts();
    await _importDocuments();
    await _importConversions();
    await _importPayments();
    await _importExpenses();
    await _reconcileBalances();
    await _importOpeningBalances();
    await _advanceSequences();
    await _enqueueReconciledDocuments();

    for (final warning in _pendingWarnings) {
      if (!warnings.contains(warning)) warnings.add(warning);
    }
  }

  Future<FirmEntity> createFirm() {
    final row = snapshot.firm;
    final gstin = validGstin(cleanString(row['firm_gstin_number']));
    final name = VyaparImportService._firmName(snapshot);
    return db.firmRepository.create(
      name: name,
      legalName: name,
      gstin: gstin,
      pan: panFromGstin(gstin),
      stateCode:
          IndianStates.byName(cleanString(row['firm_state']))?.code ??
          IndianStates.stateCodeFromGstin(gstin),
      addressLine1: cleanString(row['firm_address']),
      pincode: cleanString(row['firm_pincode']),
      phone:
          cleanString(row['firm_phone']) ??
          cleanString(row['firm_phone_secondary']),
      email: cleanString(row['firm_email']),
    );
  }

  /// Pulls the item and party details every line and document needs up front.
  void _indexLookups() {
    for (final row in snapshot.items) {
      final id = asInt(row['item_id']);
      if (id == null) continue;
      itemName[id] = cleanString(row['item_name']) ?? '';
      itemHsn[id] = cleanString(row['item_hsn_sac_code']);
      itemGstRate[id] = snapshot.taxRates[asInt(row['item_tax_id'])] ?? 0;
    }
    for (final row in snapshot.parties) {
      final id = asInt(row['name_id']);
      if (id == null) continue;
      partyName[id] =
          cleanString(row['full_name']) ??
          cleanString(row['party_billing_name']) ??
          '';
    }
  }

  // ---- Units and categories ---------------------------------------------

  Future<void> _importUnits() async {
    final items = db.itemRepositoryFor(firm.id);
    for (final row in snapshot.units) {
      final id = asInt(row['unit_id']);
      if (id == null) continue;
      final name = cleanString(row['unit_name']);
      final short = cleanString(row['unit_short_name']);
      final standard = _standardUnitId(name, short);
      if (standard != null) {
        unitIds[id] = standard;
        continue;
      }
      if (name == null && short == null) continue;
      final created = await items.createUnit(name ?? short!, short ?? name!);
      unitIds[id] = created.id;
      counts.units++;
    }
  }

  Future<void> _importCategories() async {
    final items = db.itemRepositoryFor(firm.id);
    for (final row in snapshot.itemCategories) {
      final id = asInt(row['item_category_id']);
      final name = cleanString(row['item_category_name']);
      if (id == null || name == null) continue;
      final created = await items.createCategory(name);
      categoryIds[id] = created.id;
      counts.categories++;
    }
    // Vyapar keeps expense heads among its parties (`name_type = 2`). They are
    // not parties at all, so they become expense categories rather than
    // customers nobody ever billed.
    for (final row in snapshot.expenseHeads) {
      final name = cleanString(row['full_name']);
      if (name == null) continue;
      await items.createCategory(name, kind: 'expense');
      counts.categories++;
    }
  }

  // ---- Parties -----------------------------------------------------------

  Future<void> _importParties() async {
    final repo = db.partyRepositoryFor(firm.id);
    final types = _partyTypes(snapshot);

    for (final row in snapshot.parties) {
      final id = asInt(row['name_id']);
      final name = partyName[id] ?? '';
      if (id == null || name.isEmpty) continue;

      final rawGstin = cleanString(row['name_gstin_number']);
      final gstin = validGstin(rawGstin);
      if (rawGstin != null && gstin == null && !_warnedAboutGstin) {
        // Dropping a malformed GSTIN is right — it must never print on an
        // invoice — but it is the user's data, so say so rather than let it
        // vanish between the old app and this one.
        _warnedAboutGstin = true;
        _warn(
          'At least one party had a GSTIN that is not a valid 15-character '
          'number. Those were left behind and the parties marked unregistered.',
        );
      }
      final address = _parseAddress(cleanString(row['address']));
      final stateCode =
          IndianStates.byName(cleanString(row['name_state']))?.code ??
          IndianStates.stateCodeFromGstin(gstin);

      final party = await repo.create(
        name: name,
        type: types[id] ?? 'customer',
        gstin: gstin,
        pan: panFromGstin(gstin),
        gstType: _gstType(row, gstin),
        phone: cleanString(row['phone_number']),
        email: cleanString(row['email']),
        addressLine1: address.line1,
        addressLine2: address.line2,
        city: address.city,
        stateCode: stateCode,
        pincode: cleanString(row['pincode']) ?? address.pincode,
        creditLimit: asInt(row['credit_limit_enabled']) == 1
            ? asDouble(row['credit_limit'])
            : null,
      );
      partyIds[id] = party.id;
      counts.parties++;
    }
  }

  // ---- Items -------------------------------------------------------------

  Future<void> _importItems() async {
    final repo = db.itemRepositoryFor(firm.id);
    // An item's Vyapar stock is where the balance *ends up*, so the opening
    // figure has to give back whatever the invoices and bills below will post.
    final stockDelta = _stockDeltaByItem(snapshot);

    for (final row in snapshot.items) {
      final id = asInt(row['item_id']);
      final name = itemName[id] ?? '';
      if (id == null || name.isEmpty) continue;
      var importedName = name;
      var description =
          cleanString(row['item_description']) ??
          cleanString(row['item_catalogue_description']);
      if (name.length > 200) {
        // Drift validates UTF-16 length. Avoid splitting a surrogate pair.
        var end = 200;
        final last = name.codeUnitAt(end - 1);
        if (last >= 0xD800 && last <= 0xDBFF) end--;
        importedName = name.substring(0, end).trimRight();
        description = [
          if (description != null) description,
          'Original Vyapar item name: $name',
        ].join('\n\n');
        _warn(
          'Item $id had a name longer than 200 characters. The catalogue name '
          'was shortened and the full original name was saved in its description.',
        );
      }

      final gstRate = itemGstRate[id] ?? 0;
      final hsn = itemHsn[id];
      final unit = unitIds[asInt(row['base_unit_id'])] ?? 'pcs';
      final itemType = asInt(row['item_type']);
      final vyaparStock = asDouble(row['item_stock_quantity']);
      final stockFromDocuments = stockDelta[id] ?? 0;
      final openingStock = vyaparStock - stockFromDocuments;

      // Vyapar tracks stock on services too — an annual maintenance contract
      // routinely sits at a negative quantity — but Apex Books stops moving stock
      // entirely for anything flagged as a service. So the flag is only applied
      // to items that genuinely carry no stock; otherwise the quantity would
      // quietly vanish from the stock report.
      final carriesStock = vyaparStock != 0 || stockFromDocuments != 0;
      final isService =
          !carriesStock &&
          _looksLikeService(itemType: itemType, hsn: hsn, unit: unit);

      if (asDouble(row['item_additional_cess_per_unit']) != 0) {
        _warn(
          'Item-level additional cess could not be imported — Vyapar stores it '
          'per unit and Apex Books stores a percentage.',
        );
      }

      final item = await repo.create(
        name: importedName,
        sku: cleanString(row['item_code']),
        hsn: hsn,
        categoryId: categoryIds[asInt(row['category_id'])],
        unit: unit,
        salePrice: asDouble(row['item_sale_unit_price']),
        purchasePrice: asDouble(row['item_purchase_unit_price']),
        wholesalePrice: _positiveOrNull(row['item_wholesale_price']),
        mrp: _positiveOrNull(row['item_mrp']),
        gstRate: gstRate,
        isService: isService,
        stockType: isService ? 'untracked' : 'tracked',
        openingStock: openingStock,
        lowStockAlert: asDouble(row['item_min_stock_quantity']),
        description: description,
      );
      itemIds[id] = item.id;
      itemUnit[id] = unit;
      counts.items++;
    }
  }

  double _paise(double value) => Money.round2(Money.of(value)).toDouble();

  // Repository inserts precede source amount/balance reconciliation. Sync must
  // also receive the final rows, rather than only the calculated draft values.
  Future<void> _enqueueReconciledDocuments() async {
    for (final row in await (db.select(
      db.bankAccounts,
    )..where((t) => t.firmId.equals(firm.id))).get()) {
      await enqueue(
        firmId: firm.id,
        entity: 'bank_accounts',
        entityId: row.id,
        operation: 'update',
        payload: jsonEncode(row.toJson()),
      );
    }
    for (final row in await (db.select(
      db.salesInvoices,
    )..where((t) => t.firmId.equals(firm.id))).get()) {
      await enqueue(
        firmId: firm.id,
        entity: 'sales_invoices',
        entityId: row.id,
        operation: 'update',
        payload: jsonEncode(row.toJson()),
      );
      for (final line
          in await db.salesRepositoryFor(firm.id).itemsFor(row.id)) {
        await enqueue(
          firmId: firm.id,
          entity: 'sales_invoice_items',
          entityId: line.id,
          operation: 'update',
          payload: jsonEncode(line.toJson()),
        );
      }
    }
    for (final row in await (db.select(
      db.purchaseBills,
    )..where((t) => t.firmId.equals(firm.id))).get()) {
      await enqueue(
        firmId: firm.id,
        entity: 'purchase_bills',
        entityId: row.id,
        operation: 'update',
        payload: jsonEncode(row.toJson()),
      );
      for (final line
          in await db.purchaseRepositoryFor(firm.id).itemsFor(row.id)) {
        await enqueue(
          firmId: firm.id,
          entity: 'purchase_bill_items',
          entityId: line.id,
          operation: 'update',
          payload: jsonEncode(line.toJson()),
        );
      }
    }
  }

  bool _isIncoming(VyaparDocKind kind) =>
      kind == VyaparDocKind.saleInvoice ||
      kind == VyaparDocKind.saleOrder ||
      kind == VyaparDocKind.quotation;

  int? _paymentTypeFor(VyaparDocument document) {
    for (final split in snapshot.paymentSplits) {
      if (split.documentTxnId == document.id && split.amount > 0) {
        return split.paymentTypeId;
      }
    }
    return document.paymentTypeId;
  }

  Future<void> _importAccounts() async {
    for (final entry in snapshot.paymentTypes.entries) {
      final row = entry.value;
      final type = (cleanString(row['paymentType_type']) ?? '').toLowerCase();
      if (!['cash', 'bank', 'card'].contains(type)) continue;
      final id = IdUtils.newId();
      final opening = asDouble(row['paymentType_opening_balance']);
      await db
          .into(db.bankAccounts)
          .insert(
            BankAccountsCompanion.insert(
              id: id,
              firmId: firm.id,
              name: cleanString(row['paymentType_name']) ?? type,
              type: Value(type),
              currentBalance: Value(opening),
              openingBalance: Value(opening),
              bankName: Value(cleanString(row['paymentType_bankName'])),
              accountNumber: Value(
                cleanString(row['paymentType_accountNumber']),
              ),
              ifsc: Value(cleanString(row['pt_bank_ifsc_code'])),
              accountHolder: Value(
                cleanString(row['pt_bank_account_holder_name']),
              ),
              upiId: Value(cleanString(row['pt_bank_upi_id'])),
            ),
          );
      paymentAccountIds[entry.key] = id;
      final saved = await (db.select(
        db.bankAccounts,
      )..where((t) => t.id.equals(id))).getSingle();
      await enqueue(
        entity: 'bank_accounts',
        entityId: id,
        operation: 'insert',
        payload: jsonEncode(saved.toJson()),
        firmId: firm.id,
      );
      if (opening != 0) {
        _warn(
          'Bank opening balances were retained in account balances; review opening ledger entries.',
        );
      }
    }
  }

  Future<void> _importConversions() async {
    final converted = <int>{};
    for (final row in snapshot.conversions) {
      final source = asInt(row['txn_source_id']);
      final target = documentIds[asInt(row['txn_destination_id'])];
      final id = documentIds[source];
      if (id == null ||
          target == null ||
          importedKinds[source] != VyaparDocKind.quotation) {
        continue;
      }
      converted.add(source!);
      await (db.update(db.salesInvoices)..where((t) => t.id.equals(id))).write(
        SalesInvoicesCompanion(
          convertedToInvoiceId: Value(target),
          convertedAt: Value(DateTime.tryParse('${row['txns_linked_date']}')),
        ),
      );
    }
    for (final document in snapshot.documents) {
      final id = documentIds[document.id];
      if (id == null ||
          document.kind != VyaparDocKind.quotation ||
          document.status != 4 ||
          converted.contains(document.id)) {
        continue;
      }
      await (db.update(db.salesInvoices)..where((t) => t.id.equals(id))).write(
        const SalesInvoicesCompanion(status: Value('cancelled')),
      );
    }
  }

  Future<void> _preserveDocumentAmounts(
    VyaparDocument document,
    String id,
  ) async {
    final sale =
        document.kind != VyaparDocKind.purchaseBill &&
        document.kind != VyaparDocKind.purchaseOrder;
    final header = sale ? 'sales_invoices' : 'purchase_bills';
    final linesTable = sale ? 'sales_invoice_items' : 'purchase_bill_items';
    final parent = sale ? 'invoice_id' : 'bill_id';
    final savedLines = await db
        .customSelect(
          'SELECT id FROM $linesTable WHERE $parent = ? ORDER BY sort_order',
          variables: [Variable<String>(id)],
        )
        .get();
    final sourceLines = snapshot.linesByTxn[document.id] ?? [];
    final party = await _partyFor(
      db.partyRepositoryFor(firm.id),
      document.nameId,
    );
    final interstate = _isInterState(party);
    double rawTax = 0;
    for (var i = 0; i < sourceLines.length; i++) {
      final line = sourceLines[i];
      rawTax += line.taxAmount;
      final total = _paise(line.total);
      final tax = _paise(line.taxAmount);
      final cgst = interstate ? 0.0 : _paise(tax / 2);
      await db.customUpdate(
        'UPDATE $linesTable SET total = ?, taxable_value = ?, cgst = ?, sgst = ?, igst = ? WHERE id = ?',
        variables: [
          Variable<double>(total),
          Variable<double>(_paise(total - tax)),
          Variable<double>(cgst),
          Variable<double>(interstate ? 0 : _paise(tax - cgst)),
          Variable<double>(interstate ? tax : 0),
          Variable<String>(savedLines[i].read<String>('id')),
        ],
      );
    }
    final total = _paise(document.cashAmount + document.balanceAmount);
    final tax = _paise(rawTax);
    final cgst = interstate ? 0.0 : _paise(tax / 2);
    await db.customUpdate(
      'UPDATE $header SET grand_total = ?, taxable_value = ?, cgst = ?, sgst = ?, igst = ?, round_off = ? WHERE id = ?',
      variables: [
        Variable<double>(total),
        Variable<double>(
          _paise(total - tax - document.additionalCharges - document.roundOff),
        ),
        Variable<double>(cgst),
        Variable<double>(interstate ? 0 : _paise(tax - cgst)),
        Variable<double>(interstate ? tax : 0),
        Variable<double>(_paise(document.roundOff)),
        Variable<String>(id),
      ],
    );
  }

  // ---- Documents ---------------------------------------------------------

  Future<void> _importDocuments() async {
    final sales = db.salesRepositoryFor(firm.id);
    final purchases = db.purchaseRepositoryFor(firm.id);
    final parties = db.partyRepositoryFor(firm.id);

    for (final document in snapshot.documents) {
      switch (document.kind) {
        case VyaparDocKind.saleInvoice:
        case VyaparDocKind.quotation:
        case VyaparDocKind.saleOrder:
        case VyaparDocKind.deliveryNote:
          final lines = _linesFor(document);
          if (lines == null) continue;
          final party = await _partyFor(parties, document.nameId);
          final saved = await sales.save(
            SalesDraft(
              id: IdUtils.newId(),
              number: _uniqueNumber(document),
              docType: _salesDocType(document.kind),
              partyId: party?.atriaId,
              invoiceDate: document.date ?? DateTime.now(),
              // Vyapar's generic due date is also populated on open estimates.
              // It is not an explicit quotation validity deadline.
              dueDate: document.kind == VyaparDocKind.quotation
                  ? null
                  : document.dueDate,
              status: 'confirmed',
              lines: lines.map((e) => e.sales).toList(),
              partyName: party?.name,
              partyGstin: party?.gstin,
              partyGstType: party?.gstType,
              partyPhone: party?.phone,
              billingAddress:
                  document.billingAddress ?? _partyAddress(party?.entity),
              shippingAddress: document.shippingAddress,
              placeOfSupply: _placeOfSupply(document, party),
              isInterState: _isInterState(party),
              invoiceDiscountAmount: _decimalOrNull(document.discountAmount),
              invoiceDiscountPercent: _decimalOrNull(document.discountPercent),
              notes: document.notes,
              shippingCharge: decimal(document.additionalCharges),
              applyRoundOff: false,
            ),
            // Only a real invoice moves goods. Apex Books's sales repository already
            // skips quotations and delivery notes, but it does *not* skip
            // sales orders, so an order would have deducted stock here.
            affectStock: document.kind == VyaparDocKind.saleInvoice,
          );
          await _preserveDocumentAmounts(document, saved.id);
          _recordImported(
            document,
            saved.id,
            _paise(document.cashAmount + document.balanceAmount),
          );
          _countSales(document.kind);
          break;

        case VyaparDocKind.purchaseBill:
        case VyaparDocKind.purchaseOrder:
          final lines = _linesFor(document);
          if (lines == null) continue;
          final party = await _partyFor(parties, document.nameId);
          final saved = await purchases.save(
            PurchaseDraft(
              id: IdUtils.newId(),
              number: _uniqueNumber(document),
              docType: document.kind == VyaparDocKind.purchaseBill
                  ? 'bill'
                  : 'purchase_order',
              partyId: party?.atriaId,
              // Vyapar keeps the supplier's own number here for bills, which is
              // exactly what this field is for. (For orders it echoes the order
              // number, which is harmless.)
              supplierInvoiceNumber: document.number,
              billDate: document.date ?? DateTime.now(),
              dueDate: document.dueDate,
              status: 'confirmed',
              lines: lines.map((e) => e.purchase).toList(),
              partyName: party?.name,
              partyGstin: party?.gstin,
              partyGstType: party?.gstType,
              partyPhone: party?.phone,
              billingAddress:
                  document.billingAddress ?? _partyAddress(party?.entity),
              placeOfSupply: _placeOfSupply(document, party),
              isInterState: _isInterState(party),
              invoiceDiscountAmount: _decimalOrNull(document.discountAmount),
              notes: document.notes,
              shippingCharge: decimal(document.additionalCharges),
              applyRoundOff: false,
            ),
            affectStock: document.kind == VyaparDocKind.purchaseBill,
          );
          await _preserveDocumentAmounts(document, saved.id);
          _recordImported(
            document,
            saved.id,
            _paise(document.cashAmount + document.balanceAmount),
          );
          if (document.kind == VyaparDocKind.purchaseBill) {
            counts.purchaseBills++;
          } else {
            counts.purchaseOrders++;
          }
          break;

        case VyaparDocKind.paymentIn:
        case VyaparDocKind.paymentOut:
        case VyaparDocKind.unsupported:
          break;
      }
    }
  }

  /// Builds both line forms in one pass, or returns null (and reports it) when
  /// Vyapar holds a document with no lines.
  List<_LinePair>? _linesFor(VyaparDocument document) {
    final lines = snapshot.linesByTxn[document.id] ?? const <VyaparLine>[];
    if (lines.isEmpty) {
      counts.skipped++;
      _warn('Documents with no line items were skipped.');
      return null;
    }
    return [
      for (final line in lines)
        _LinePair(
          sales: SalesLineDraft(
            id: IdUtils.newId(),
            itemId: itemIds[line.itemId],
            name: _lineName(line),
            hsn: itemHsn[line.itemId],
            quantity: decimal(line.quantity),
            unit: _lineUnit(line),
            rate: decimal(line.price),
            discountPercent: _decimalOrNull(line.discountPercent),
            discountAmount: _decimalOrNull(line.discountAmount),
            gstRate:
                snapshot.taxRates[line.taxId] ?? itemGstRate[line.itemId] ?? 0,
          ),
          purchase: PurchaseLineDraft(
            id: IdUtils.newId(),
            itemId: itemIds[line.itemId],
            name: _lineName(line),
            hsn: itemHsn[line.itemId],
            quantity: decimal(line.quantity),
            unit: _lineUnit(line),
            rate: decimal(line.price),
            discountPercent: _decimalOrNull(line.discountPercent),
            gstRate:
                snapshot.taxRates[line.taxId] ?? itemGstRate[line.itemId] ?? 0,
          ),
        ),
    ];
  }

  String _lineName(VyaparLine line) {
    final name = itemName[line.itemId] ?? '';
    if (name.isNotEmpty) return name;
    return cleanString(line.description) ?? 'Item';
  }

  String _lineUnit(VyaparLine line) {
    final byLine = unitIds[line.unitId];
    if (byLine != null) return byLine;
    return itemUnit[line.itemId] ?? 'pcs';
  }

  void _recordImported(VyaparDocument document, String atriaId, double total) {
    importedKinds[document.id] = document.kind;
    documentIds[document.id] = atriaId;
    documentTotals[document.id] = total;
  }

  void _countSales(VyaparDocKind kind) {
    switch (kind) {
      case VyaparDocKind.saleInvoice:
        counts.saleInvoices++;
      case VyaparDocKind.quotation:
        counts.quotations++;
      case VyaparDocKind.saleOrder:
        counts.saleOrders++;
      case VyaparDocKind.deliveryNote:
        counts.deliveryNotes++;
      default:
        break;
    }
  }

  // ---- Payments ----------------------------------------------------------

  Future<void> _importPayments() async {
    final payments = db.paymentRepositoryFor(firm.id);
    final sales = db.salesRepositoryFor(firm.id);
    final purchases = db.purchaseRepositoryFor(firm.id);

    // Documents settled by a payment transaction of their own. Vyapar leaves a
    // zero-amount row in `txn_payment_mapping` for these, but a partial payment
    // can leave a real one, so the amount already recorded is tracked and only
    // the remainder is attributed below.
    final linksByTxn = <int, List<VyaparPaymentLink>>{};
    for (final link in snapshot.paymentLinks) {
      (linksByTxn[link.paymentTxnId] ??= []).add(link);
    }

    for (final document in snapshot.documents) {
      final isIn = document.kind == VyaparDocKind.paymentIn;
      final isOut = document.kind == VyaparDocKind.paymentOut;
      if (!isIn && !isOut) continue;

      final amount = document.cashAmount > 0
          ? document.cashAmount
          : document.balanceAmount;
      if (amount <= 0) {
        counts.skipped++;
        continue;
      }

      // A payment against an order or an estimate is an advance: real money,
      // but not the settlement of a ledger document. It is kept, and named,
      // rather than applied to a balance it would distort.
      final documentLinks =
          linksByTxn[document.id] ?? const <VyaparPaymentLink>[];
      VyaparPaymentLink? ledgerLink;
      for (final link in documentLinks) {
        if (importedKinds[link.documentTxnId]?.isLedgerDocument ?? false) {
          ledgerLink = link;
          break;
        }
      }
      final targetLink =
          ledgerLink ?? (documentLinks.isEmpty ? null : documentLinks.first);
      final atriaId = targetLink == null
          ? null
          : documentIds[targetLink.documentTxnId];

      await payments.create(
        type: isIn ? 'payment_in' : 'payment_out',
        number: _paymentNumber(document.number, document.id),
        partyId: partyIds[document.nameId],
        partyName: partyName[document.nameId],
        amount: amount,
        date: document.date ?? DateTime.now(),
        mode: _paymentMode(_paymentTypeFor(document), null),
        bankAccountId: paymentAccountIds[_paymentTypeFor(document)],
        reference: document.paymentReference,
        linkedInvoiceId: atriaId,
        linkedInvoiceNumber: atriaId == null
            ? _documentNumber(targetLink?.documentTxnId)
            : null,
        notes: atriaId == null && targetLink != null
            ? 'Advance from Vyapar'
            : null,
        onLinked: ledgerLink == null
            ? null
            : isIn
            ? (id, value) => sales.applyPayment(invoiceId: id, amount: value)
            : (id, value) => purchases.applyPayment(billId: id, amount: value),
      );
      counts.payments++;
      if (targetLink != null) {
        settledByPaymentTxn.update(
          targetLink.documentTxnId,
          (value) => value + amount,
          ifAbsent: () => amount,
        );
      }
    }

    // Everything else was settled through `txn_payment_mapping`, which records
    // the mode and amount of each payment against a document.
    final documentByTxnId = {
      for (final document in snapshot.documents) document.id: document,
    };
    final numberSuffix = <String, int>{};

    for (final split in snapshot.paymentSplits) {
      final kind = importedKinds[split.documentTxnId];
      if (kind == null || split.amount <= 0) continue;
      final document = documentByTxnId[split.documentTxnId];
      final atriaId = documentIds[split.documentTxnId];
      if (document == null || atriaId == null) continue;

      final remaining = _paise(split.amount);
      if (remaining <= 0.0001) continue;

      final base = _paymentNumber(document.number, document.id);
      final seen = numberSuffix.update(base, (v) => v + 1, ifAbsent: () => 1);

      await payments.create(
        type: _isIncoming(kind) ? 'payment_in' : 'payment_out',
        number: seen == 1 ? base : '$base-$seen',
        partyId: partyIds[document.nameId],
        partyName: partyName[document.nameId],
        amount: remaining,
        date: document.date ?? DateTime.now(),
        mode: _paymentMode(split.paymentTypeId, split.reference),
        bankAccountId: paymentAccountIds[split.paymentTypeId],
        reference: split.reference,
        linkedInvoiceId: atriaId,
        onLinked: !kind.isLedgerDocument
            ? null
            : kind == VyaparDocKind.saleInvoice
            ? (id, value) => sales.applyPayment(invoiceId: id, amount: value)
            : (id, value) => purchases.applyPayment(billId: id, amount: value),
      );
      counts.payments++;
      paidBySplit.update(
        split.documentTxnId,
        (value) => value + remaining,
        ifAbsent: () => remaining,
      );
    }
  }

  // ---- Expenses ----------------------------------------------------------

  /// Writes Vyapar's journal-entry expenses and other income to Apex Books.
  ///
  /// The reader has already thrown away anything whose two sides it could not
  /// tell apart, so every entry here is a real book entry: an expense head paid
  /// out of cash or bank. Nothing links them to the party balances, so this runs
  /// after the documents without disturbing them.
  Future<void> _importExpenses() async {
    if (snapshot.expenses.isEmpty) return;
    final expenses = db.expenseRepositoryFor(firm.id);

    // Vyapar's own reference is kept when it has one, so `EXP-3` in Vyapar is
    // `EXP-3` in Apex Books and the two books can be read side by side.
    final used = <String>{};
    var fallback = 0;
    for (final expense in snapshot.expenses) {
      var number = expense.reference.trim();
      if (number.isEmpty) {
        fallback++;
        number = 'EXP-${fallback.toString().padLeft(4, '0')}';
      }
      while (!used.add(number)) {
        number = '$number-2';
      }

      await expenses.create(
        type: expense.type,
        number: number,
        category: expense.category,
        amount: expense.amount,
        date: expense.date ?? DateTime.now(),
        mode: expense.mode,
        notes: expense.notes,
      );
      counts.expenses++;
    }
  }

  // ---- Reconciliation ----------------------------------------------------

  /// Rewrites every imported document's paid amount, balance and status from
  /// Vyapar's own figures.
  ///
  /// The payments above get most of the way there, but Vyapar is the source of
  /// truth for what is still owed. Re-deriving it would let rounding — and any
  /// document type Apex Books does not import — drift the ageing report away from
  /// what the user was looking at before switching.
  Future<void> _reconcileBalances() async {
    for (final document in snapshot.documents) {
      final kind = importedKinds[document.id];
      if (kind == null) continue;
      final grandTotal = documentTotals[document.id];
      final atriaId = documentIds[document.id];
      if (grandTotal == null || atriaId == null) continue;
      if (!kind.isLedgerDocument) continue;

      final outstanding = _outstanding(document, grandTotal).toDouble();
      final paid = grandTotal - outstanding;
      final status = outstanding <= 0.01
          ? 'paid'
          : (paid <= 0.01 ? 'unpaid' : 'partial');

      if (kind == VyaparDocKind.saleInvoice) {
        await (db.update(
          db.salesInvoices,
        )..where((t) => t.id.equals(atriaId))).write(
          SalesInvoicesCompanion(
            paidAmount: Value(paid),
            balanceDue: Value(outstanding),
            paymentStatus: Value(status),
            updatedAt: Value(DateTime.now()),
          ),
        );
      } else {
        await (db.update(
          db.purchaseBills,
        )..where((t) => t.id.equals(atriaId))).write(
          PurchaseBillsCompanion(
            paidAmount: Value(paid),
            balanceDue: Value(outstanding),
            paymentStatus: Value(status),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }
    }
  }

  /// Sets each party's opening balance to the part of Vyapar's balance that the
  /// imported documents do not already explain.
  ///
  /// When every document came across this is zero, which is the point: it only
  /// moves when the backup holds something Apex Books did not import, and then it
  /// keeps the party's statement agreeing with Vyapar instead of silently
  /// losing the difference.
  Future<void> _importOpeningBalances() async {
    final explained = <int, double>{};
    for (final document in snapshot.documents) {
      final kind = importedKinds[document.id];
      final grandTotal = documentTotals[document.id];
      final nameId = document.nameId;
      if (kind == null || grandTotal == null || nameId == null) continue;
      final outstanding = _outstanding(document, grandTotal);
      if (kind == VyaparDocKind.saleInvoice) {
        explained.update(
          nameId,
          (value) => value + outstanding,
          ifAbsent: () => outstanding,
        );
      } else if (kind == VyaparDocKind.purchaseBill) {
        explained.update(
          nameId,
          (value) => value - outstanding,
          ifAbsent: () => -outstanding,
        );
      }
    }

    final repo = db.partyRepositoryFor(firm.id);
    for (final row in snapshot.parties) {
      final nameId = asInt(row['name_id']);
      if (nameId == null) continue;
      final atriaId = partyIds[nameId];
      if (atriaId == null) continue;

      final statement = await db
          .reportRepositoryFor(firm.id)
          .partyStatement(partyId: atriaId);
      final residual = _paise(
        asDouble(row['amount']) - statement.closing.toDouble(),
      );
      if (residual.abs() < 0.01) continue;

      final party = await repo.getById(atriaId);
      if (party == null) continue;
      await repo.update(
        party.copyWith(
          openingBalance: residual.abs(),
          openingBalanceType: residual >= 0 ? 'dr' : 'cr',
          updatedAt: DateTime.now(),
        ),
      );
    }
  }

  /// Outstanding on a document, from Vyapar's own balance less whatever was
  /// settled by a standalone payment transaction against it.
  double _outstanding(VyaparDocument document, double grandTotal) =>
      _paise(document.balanceAmount - (settledByPaymentTxn[document.id] ?? 0))
          .clamp(0, grandTotal)
          .toDouble();

  /// Moves Apex Books's own counters past the numbers Vyapar already used, so the
  /// next invoice the user raises does not repeat an imported one.
  Future<void> _advanceSequences() async {
    int highest(VyaparDocKind kind) {
      var top = 0;
      for (final document in snapshot.documents) {
        if (document.kind != kind) continue;
        final value = int.tryParse((document.number ?? '').split('/').last);
        if (value != null && value > top) top = value;
      }
      return top;
    }

    final invoice = highest(VyaparDocKind.saleInvoice);
    final quotation = highest(VyaparDocKind.quotation);
    final salesOrder = highest(VyaparDocKind.saleOrder);
    final purchase = highest(VyaparDocKind.purchaseBill);
    if (invoice + quotation + salesOrder + purchase == 0) return;

    await (db.update(db.firms)..where((t) => t.id.equals(firm.id))).write(
      FirmsCompanion(
        invoiceSequence: Value(
          invoice > firm.invoiceSequence ? invoice : firm.invoiceSequence,
        ),
        quotationSequence: Value(
          quotation > firm.quotationSequence
              ? quotation
              : firm.quotationSequence,
        ),
        salesOrderSequence: Value(
          salesOrder > firm.salesOrderSequence
              ? salesOrder
              : firm.salesOrderSequence,
        ),
        purchaseSequence: Value(
          purchase > firm.purchaseSequence ? purchase : firm.purchaseSequence,
        ),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  // ---- Per-document helpers ---------------------------------------------

  /// Whether Vyapar had this company registered for GST.
  ///
  /// `kb_firms` holds no such flag — a company with no GSTIN is simply one that
  /// is not registered — so the switch in `kb_settings` decides, and a valid
  /// firm GSTIN is taken as confirmation for older backups that lack the key.
  bool _resolveCompanyGstRegistration() {
    if (snapshot.settings['VYAPAR.GSTENABLED'] == '0') return false;
    return (firm.gstin ?? '').isNotEmpty;
  }

  /// Vyapar's own registration flag on a party, which is `name_customer_type`.
  ///
  /// Verified in a real backup: every party with `1` carries a 15-character
  /// GSTIN and every one with `0` carries none, so it is the authoritative
  /// field rather than something to infer from the GSTIN's length. It still
  /// cannot make a party registered *without* a GSTIN — nothing downstream can
  /// treat a GSTIN-less party as B2B — so that case falls back to unregistered
  /// (and [gstinDropped] has already warned about the GSTIN being unreadable).
  static String _gstType(Map<String, Object?> row, String? gstin) {
    switch (asInt(row['name_customer_type'])) {
      case 1:
        return gstin == null ? 'unregistered' : 'registered';
      case 0:
        return 'unregistered';
    }
    return gstin == null ? 'unregistered' : 'registered';
  }

  Future<_PartyRef?> _partyFor(PartyRepository repo, int? nameId) async {
    if (nameId == null) return null;
    final atriaId = partyIds[nameId];
    if (atriaId == null) return null;
    final entity = await repo.getById(atriaId);
    if (entity == null) return null;
    return _PartyRef(atriaId: atriaId, entity: entity, name: entity.name);
  }

  /// Inter-state must be decided **exactly** as the sale editor decides it, or
  /// a document created here and the same document re-saved in the UI would
  /// disagree about IGST versus CGST/SGST.
  ///
  /// The editor requires both sides to be GST registered and only then compares
  /// states, so an unregistered buyer in another state is taxed as a local
  /// supply. That also feeds GSTR-1, where `isInterState` is what separates
  /// B2CL from B2CS — so guessing here would move invoices between tables.
  bool _isInterState(_PartyRef? party) {
    if ((firm.gstin ?? '').isEmpty) return false;
    if (party == null) return false;
    if ((party.gstin ?? '').isEmpty) return false;
    final partyState = party.stateCode ?? firm.stateCode;
    return partyState != firm.stateCode;
  }

  /// The place of supply the party carries, falling back to the one Vyapar
  /// stamped on the document (which is the statutory one when the party record
  /// was left blank), and then to the firm's own state.
  String? _placeOfSupply(VyaparDocument document, _PartyRef? party) =>
      party?.stateCode ??
      IndianStates.byName(document.placeOfSupply)?.code ??
      firm.stateCode;

  String? _documentNumber(int? vyaparTxnId) {
    if (vyaparTxnId == null) return null;
    for (final document in snapshot.documents) {
      if (document.id == vyaparTxnId) return document.number;
    }
    return null;
  }

  /// Keeps a document's own number, making it unique inside its series.
  String _uniqueNumber(VyaparDocument document) {
    var base = (document.number ?? '').trim();
    if (base.isEmpty) base = 'VYP-${document.id}';
    if (base.length > 32) base = base.substring(0, 32);

    final used = usedNumbers.putIfAbsent(document.kind.name, () => {});
    var candidate = base;
    var suffix = 2;
    while (!used.add(candidate)) {
      candidate = '$base-$suffix';
      suffix++;
    }
    return candidate;
  }

  static String _paymentNumber(String? reference, int txnId) {
    final trimmed = reference?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return 'VYP-$txnId';
  }

  String _paymentMode(int? paymentTypeId, String? reference) {
    final ref = (reference ?? '').toUpperCase();
    if (ref.contains('UPI')) return 'upi';
    if (ref.contains('CHEQUE')) return 'cheque';

    final type = paymentTypeId == null
        ? null
        : snapshot.paymentTypes[paymentTypeId];
    switch ((cleanString(type?['paymentType_type']) ?? '').toUpperCase()) {
      case 'CASH':
        return 'cash';
      case 'CHEQUE':
        return 'cheque';
      case 'BANK':
        return 'bank_transfer';
      case 'CARD':
        return 'card';
    }
    // Vyapar leaves the mode unset on plenty of receipts. Cash is the honest
    // default — it is the only mode that needs nothing else to exist.
    return 'cash';
  }

  void _warn(String message) {
    if (!_pendingWarnings.contains(message)) _pendingWarnings.add(message);
  }
}

class _LinePair {
  const _LinePair({required this.sales, required this.purchase});

  final SalesLineDraft sales;
  final PurchaseLineDraft purchase;
}

class _PartyRef {
  const _PartyRef({
    required this.atriaId,
    required this.entity,
    required this.name,
  });

  final String atriaId;
  final PartyEntity entity;
  final String name;

  String? get gstin => entity.gstin;
  String? get gstType => entity.gstType;
  String? get phone => entity.phone;
  String? get stateCode => entity.stateCode;
}

// ---- Shared pure helpers -------------------------------------------------

/// Vyapar units are a fixed list of thirty; Apex Books ships its own standard set, so
/// anything that matches maps onto it and the rest become firm-defined units
/// (which the item editor already lists alongside the standard ones).
String? _standardUnitId(String? name, String? short) {
  const byShort = <String, String>{
    'bag': 'bag',
    'box': 'box',
    'btl': 'bottle',
    'ctn': 'box',
    'dzn': 'dozen',
    'gm': 'g',
    'gms': 'g',
    'kg': 'kg',
    'kgs': 'kg',
    'ltr': 'l',
    'l': 'l',
    'ml': 'ml',
    'mtr': 'm',
    'm': 'm',
    'cm': 'cm',
    'ft': 'ft',
    'nos': 'nos',
    'no': 'nos',
    'pac': 'pkt',
    'pkt': 'pkt',
    'pcs': 'pcs',
    'pc': 'pcs',
    'prs': 'pair',
    'rol': 'roll',
    'sqf': 'sqft',
    'sqft': 'sqft',
    'sqm': 'sqm',
    'dy': 'day',
    'day': 'day',
    'hur': 'hour',
    'hr': 'hour',
    'hrs': 'hour',
    'unit': 'nos',
    'set': 'set',
    'ser': 'service',
    'svc': 'service',
    'mo': 'month',
    'mon': 'month',
  };
  final key = (short ?? name ?? '').trim().toLowerCase();
  return byShort[key];
}

bool _looksLikeService({
  required int? itemType,
  required String? hsn,
  required String unit,
}) {
  if (itemType == 2) return true;
  if (unit == 'service') return true;
  // SAC codes for services all start 99; HSN codes for goods never do.
  return (hsn?.trim() ?? '').startsWith('99');
}

/// Net stock effect of the documents about to be imported, per Vyapar item id.
/// Used to turn Vyapar's *current* stock into an opening balance.
Map<int, double> _stockDeltaByItem(VyaparSnapshot snapshot) {
  final delta = <int, double>{};
  for (final document in snapshot.documents) {
    final sign = switch (document.kind) {
      VyaparDocKind.saleInvoice => -1.0,
      VyaparDocKind.purchaseBill => 1.0,
      _ => 0.0,
    };
    if (sign == 0) continue;
    for (final line
        in snapshot.linesByTxn[document.id] ?? const <VyaparLine>[]) {
      final itemId = line.itemId;
      if (itemId == null) continue;
      delta.update(
        itemId,
        (value) => value + sign * line.quantity,
        ifAbsent: () => sign * line.quantity,
      );
    }
  }
  return delta;
}

/// Vyapar does not distinguish customers from suppliers — a party is simply a
/// party. Apex Books does, so the documents decide: whoever was invoiced is a
/// customer, whoever billed us is a supplier, and anyone both ways is both.
Map<int, String> _partyTypes(VyaparSnapshot snapshot) {
  final sells = <int>{};
  final buys = <int>{};
  for (final document in snapshot.documents) {
    final id = document.nameId;
    if (id == null) continue;
    switch (document.kind) {
      case VyaparDocKind.saleInvoice:
      case VyaparDocKind.saleOrder:
      case VyaparDocKind.quotation:
      case VyaparDocKind.deliveryNote:
      case VyaparDocKind.paymentIn:
        sells.add(id);
      case VyaparDocKind.purchaseBill:
      case VyaparDocKind.purchaseOrder:
      case VyaparDocKind.paymentOut:
        buys.add(id);
      case VyaparDocKind.unsupported:
        break;
    }
  }
  return {
    for (final id in {...sells, ...buys})
      id: sells.contains(id) && buys.contains(id)
          ? 'both'
          : (buys.contains(id) ? 'supplier' : 'customer'),
  };
}

String _salesDocType(VyaparDocKind kind) => switch (kind) {
  VyaparDocKind.quotation => 'quotation',
  VyaparDocKind.saleOrder => 'sales_order',
  VyaparDocKind.deliveryNote => 'delivery_note',
  _ => 'invoice',
};

String _partyAddress(PartyEntity? party) {
  if (party == null) return '';
  return [
    party.addressLine1,
    party.addressLine2,
    [
      party.city,
      party.pincode,
    ].where((e) => e != null && e.isNotEmpty).join(' '),
  ].where((e) => e != null && e.trim().isNotEmpty).join(', ');
}

class _ParsedAddress {
  const _ParsedAddress({this.line1, this.line2, this.city, this.pincode});

  final String? line1;
  final String? line2;
  final String? city;
  final String? pincode;
}

/// Vyapar stores one free-text address block, e.g.
/// `"8-2-350/5/1 Road Number 3 Hyderabad\nHyderabad, Telangana-500034\nIndia"`.
/// The second line carries city and pincode when the party was filled in
/// properly, which is worth picking out because Apex Books's forms and e-way bills
/// want them apart.
_ParsedAddress _parseAddress(String? raw) {
  if (raw == null) return const _ParsedAddress();
  final lines = raw
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.isEmpty) return const _ParsedAddress();

  String? line2;
  String? city;
  String? pincode;

  for (final line in lines.skip(1)) {
    if (line.toLowerCase() == 'india') continue;
    final match = RegExp(r'^(.*?),\s*(.*?)\s*-\s*(\d{6})\s*$').firstMatch(line);
    if (match != null) {
      city ??= cleanString(match.group(1));
      pincode ??= match.group(3);
      continue;
    }
    line2 ??= line;
  }

  return _ParsedAddress(
    line1: lines.first,
    line2: line2,
    city: city,
    pincode: pincode,
  );
}

String? cleanString(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? asInt(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(cleanString(value) ?? '');
}

double asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(cleanString(value) ?? '') ?? 0;
}

double? _positiveOrNull(Object? value) {
  final parsed = asDouble(value);
  return parsed > 0 ? parsed : null;
}

Decimal? _decimalOrNull(double value) => value == 0 ? null : decimal(value);

/// Rounds to the six decimals Vyapar itself stores, so a rate like
/// `5550.847457627119` survives `Decimal.parse` without float noise.
Decimal decimal(double value) => Decimal.parse(value.toStringAsFixed(6));

String? validGstin(String? value) {
  final text = value?.trim().toUpperCase();
  if (text == null || text.length != 15) return null;
  return text;
}

String? panFromGstin(String? gstin) {
  if (gstin == null || gstin.length < 12) return null;
  return gstin.substring(2, 12);
}

// ---- Counts --------------------------------------------------------------

class _MutableCounts {
  int parties = 0;
  int items = 0;
  int units = 0;
  int categories = 0;
  int expenses = 0;
  int saleInvoices = 0;
  int quotations = 0;
  int saleOrders = 0;
  int deliveryNotes = 0;
  int purchaseBills = 0;
  int purchaseOrders = 0;
  int payments = 0;
  int skipped = 0;

  VyaparImportCounts freeze() => VyaparImportCounts(
    parties: parties,
    items: items,
    units: units,
    categories: categories,
    expenses: expenses,
    saleInvoices: saleInvoices,
    quotations: quotations,
    saleOrders: saleOrders,
    deliveryNotes: deliveryNotes,
    purchaseBills: purchaseBills,
    purchaseOrders: purchaseOrders,
    payments: payments,
    skipped: skipped,
  );
}

/// What an import wrote (or would write), per entity.
class VyaparImportCounts {
  const VyaparImportCounts({
    this.parties = 0,
    this.items = 0,
    this.units = 0,
    this.categories = 0,
    this.expenses = 0,
    this.saleInvoices = 0,
    this.quotations = 0,
    this.saleOrders = 0,
    this.deliveryNotes = 0,
    this.purchaseBills = 0,
    this.purchaseOrders = 0,
    this.payments = 0,
    this.skipped = 0,
  });

  final int parties;
  final int items;
  final int units;
  final int categories;
  final int expenses;
  final int saleInvoices;
  final int quotations;
  final int saleOrders;
  final int deliveryNotes;
  final int purchaseBills;
  final int purchaseOrders;
  final int payments;
  final int skipped;

  int get documents =>
      saleInvoices +
      quotations +
      saleOrders +
      deliveryNotes +
      purchaseBills +
      purchaseOrders;

  int get total =>
      parties + items + units + categories + documents + payments + expenses;
}

/// A dry run of an import, shown to the user before anything is written.
class VyaparImportPreview {
  const VyaparImportPreview({
    required this.firmName,
    required this.counts,
    required this.warnings,
    this.gstin,
    this.state,
    this.from,
    this.to,
  });

  final String firmName;
  final String? gstin;
  final String? state;
  final DateTime? from;
  final DateTime? to;
  final VyaparImportCounts counts;
  final List<String> warnings;

  bool get isEmpty => counts.total == 0;
}

/// The outcome of a completed import.
class VyaparImportResult {
  const VyaparImportResult({
    required this.firmId,
    required this.firmName,
    required this.counts,
    required this.warnings,
  });

  final String firmId;
  final String firmName;
  final VyaparImportCounts counts;
  final List<String> warnings;
}
