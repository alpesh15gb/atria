import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Reads Vyapar's `.vyb` backup files.
///
/// A `.vyb` is a plain ZIP archive holding exactly one `.vyp` entry, and that
/// entry is an unencrypted SQLite 3 database — Vyapar's whole book. There is no
/// export API involved: the backup is just Vyapar's own database file, which is
/// why every table (`kb_transactions`, `kb_lineitems`, ...) is readable here.
///
/// This file is the *format* layer only: it opens the archive and hands back
/// [VyaparSnapshot], a version-tolerant, plain-Dart view of the tables.
/// Translating that into Apex Books's schema lives in `vyapar_import.dart`.
///
/// [VyaparBackupReader.read] never writes to the archive, and never keeps the
/// temporary extracted database alive — the caller gets values, not a handle.

/// Which Vyapar document a `kb_transactions.txn_type` code means.
///
/// Decoded from Vyapar's own seed data: `terms_and_conditions` names the
/// document and `tnc_txn_type_mapping` maps that template to its type code.
/// That table is authoritative and was read straight out of a real backup —
/// notably `28` is a **purchase order**, not a bill, and `2` is the bill.
///
/// Codes with no verified mapping stay [unsupported]; the importer counts them
/// and names them in its summary rather than guessing and corrupting stock or
/// GST returns.
enum VyaparDocKind {
  saleInvoice,
  saleOrder,
  quotation,
  deliveryNote,
  purchaseBill,
  purchaseOrder,
  paymentIn,
  paymentOut,
  unsupported;

  /// Document types that post to a party ledger in Apex Books, and so are the only
  /// ones a payment may be applied against.
  bool get isLedgerDocument => this == saleInvoice || this == purchaseBill;
}

/// Decodes `txn_type` (+ `txn_sub_type`) into a [VyaparDocKind].
///
/// The sub-type is accepted for future disambiguation but no code we have
/// verified needs it.
VyaparDocKind vyaparDocKindFor(int? type, [int? subType]) {
  switch (type) {
    case 1:
      return VyaparDocKind.saleInvoice;
    case 2:
      return VyaparDocKind.purchaseBill;
    case 3:
      return VyaparDocKind.paymentIn;
    // Symmetric counterpart of 3, which the money links pin down as
    // "Payment In". Kept out of [VyaparDocKind.isLedgerDocument] either way.
    case 4:
      return VyaparDocKind.paymentOut;
    case 24:
      return VyaparDocKind.saleOrder;
    case 27:
      // Both sub-types are the "Estimate Quotation" family in Vyapar; its
      // T&C template maps to 27 and real backups carry sub-type 0 and 1.
      return VyaparDocKind.quotation;
    case 28:
      return VyaparDocKind.purchaseOrder;
    case 30:
      return VyaparDocKind.deliveryNote;
    case 83:
      // Proforma invoice — no Apex Books equivalent, and it is a pre-sale
      // document, so it lands as a quotation rather than being dropped.
      return VyaparDocKind.quotation;
    default:
      return VyaparDocKind.unsupported;
  }
}

/// One row of `kb_transactions`, typed.
class VyaparDocument {
  VyaparDocument({
    required this.id,
    required this.kind,
    required this.txnType,
    required this.txnSubType,
    required this.status,
    required this.paymentStatus,
    this.number,
    this.paymentReference,
    this.date,
    this.dueDate,
    this.nameId,
    this.balanceAmount = 0,
    this.cashAmount = 0,
    this.roundOff = 0,
    this.discountAmount = 0,
    this.discountPercent = 0,
    this.taxAmount = 0,
    this.placeOfSupply,
    this.billingAddress,
    this.shippingAddress,
    this.notes,
    this.description,
    this.paymentTypeId,
    this.taxInclusive = false,
  });

  final int id;
  final VyaparDocKind kind;
  final int txnType;
  final int txnSubType;

  /// `txn_status`: 1 = issued document, 2 = open order, 4 = closed/converted.
  final int status;

  /// `txn_payment_status`: Vyapar's own paid flag, kept for diagnostics only —
  /// balances are reconciled from `txn_balance_amount` and the payment links.
  final int paymentStatus;

  final String? number;

  /// `txn_payment_reference` — the UTR or cheque number on a payment.
  final String? paymentReference;

  final DateTime? date;
  final DateTime? dueDate;
  final int? nameId;

  /// Outstanding on the document, as Vyapar stores it. Payments recorded as
  /// their own `txn_type` (`3`/`4`) are *not* deducted here, which is why
  /// [VyaparPaymentLink]s have to be subtracted before this is trusted.
  final double balanceAmount;
  final double cashAmount;
  final double roundOff;
  final double discountAmount;
  final double discountPercent;
  final double taxAmount;

  final String? placeOfSupply;
  final String? billingAddress;
  final String? shippingAddress;
  final String? notes;
  final String? description;
  final int? paymentTypeId;

  /// `txn_tax_inclusive` is not `!= 2`. It does not mean what it looks like:
  /// `kb_lineitems.priceperunit` is the taxable rate either way, which the
  /// importer relies on.
  final bool taxInclusive;
}

/// One row of `kb_lineitems`, typed.
class VyaparLine {
  VyaparLine({
    required this.id,
    required this.txnId,
    required this.sortOrder,
    this.itemId,
    this.unitId,
    this.taxId,
    this.quantity = 0,
    this.price = 0,
    this.total = 0,
    this.taxAmount = 0,
    this.discountAmount = 0,
    this.discountPercent = 0,
    this.cess = 0,
    this.description,
  });

  final int id;
  final int txnId;
  final int sortOrder;
  final int? itemId;
  final int? unitId;
  final int? taxId;

  final double quantity;

  /// Taxable unit rate (GST-exclusive). Verified across a real backup: every
  /// line's `total` equals `quantity * price * (1 + rate)`, so this is the
  /// pre-tax rate even when Vyapar's own tax-inclusive flag is set.
  final double price;

  /// Line total *including* GST.
  final double total;

  final double taxAmount;
  final double discountAmount;
  final double discountPercent;
  final double cess;
  final String? description;
}

/// A money movement recorded by Vyapar as a document of its own
/// (`kb_txn_links`), i.e. a "Payment In"/"Payment Out" against an invoice.
class VyaparPaymentLink {
  const VyaparPaymentLink({
    required this.paymentTxnId,
    required this.documentTxnId,
    required this.amount,
  });

  final int paymentTxnId;
  final int documentTxnId;
  final double amount;
}

/// How a document was settled, split by payment type (`txn_payment_mapping`).
///
/// `payment_id` points at `kb_paymentTypes.paymentType_id` — Cash, Cheque,
/// the firm's bank accounts — **not** at another transaction. A zero amount
/// means "nothing was paid through this mode", which is how Vyapar marks a
/// document that is settled by a separate payment transaction instead.
class VyaparPaymentSplit {
  const VyaparPaymentSplit({
    required this.paymentTypeId,
    required this.documentTxnId,
    required this.amount,
    this.reference,
  });

  final int paymentTypeId;
  final int documentTxnId;
  final double amount;
  final String? reference;
}

/// One expense (or other income) out of Vyapar's journal entries.
///
/// Vyapar does not keep expenses in `kb_transactions` — an expense is a
/// `journal_entry` that debits an expense head and credits Cash or a bank
/// account, with income as the mirror image. Only entries whose two sides can
/// be told apart are decoded into this; see `VyaparBackupReader._readExpenses`.
class VyaparExpense {
  const VyaparExpense({
    required this.id,
    required this.type,
    required this.reference,
    required this.date,
    required this.category,
    required this.amount,
    required this.mode,
    this.notes,
  });

  /// `journal_entry.id`, used to keep references stable across runs.
  final int id;

  /// Apex Books's own split: `expense` for money out, `income` for money in.
  final String type;

  /// `journal_entry.reference_number`, or a generated `VYP-JE-<id>`.
  final String reference;

  final DateTime? date;

  /// The name of the expense head (or the income account) — Apex Books's category.
  final String category;

  final double amount;

  /// `cash` or `bank_transfer`, decided by which account the money moved in.
  final String mode;

  final String? notes;
}

/// Everything the importer needs, read out of a `.vyp` database.
class VyaparSnapshot {
  VyaparSnapshot({
    required this.firm,
    required this.parties,
    required this.expenseHeads,
    required this.items,
    required this.units,
    required this.itemCategories,
    required this.partyGroups,
    required this.documents,
    required this.linesByTxn,
    required this.taxRates,
    required this.paymentTypes,
    required this.paymentLinks,
    required this.paymentSplits,
    required this.expenses,
    required this.settings,
    required this.warnings,
  });

  /// The single `kb_firms` row.
  final Map<String, Object?> firm;

  /// `kb_names` rows with `name_type = 1` — customers and suppliers.
  final List<Map<String, Object?>> parties;

  /// `kb_names` rows with `name_type = 2` — Vyapar's expense heads
  /// (Rent, Salary, Petrol...). They are names, but they behave as categories.
  final List<Map<String, Object?>> expenseHeads;

  final List<Map<String, Object?>> items;
  final List<Map<String, Object?>> units;
  final List<Map<String, Object?>> itemCategories;
  final List<Map<String, Object?>> partyGroups;

  final List<VyaparDocument> documents;
  final Map<int, List<VyaparLine>> linesByTxn;

  /// `kb_tax_code.tax_code_id` → GST rate percentage.
  final Map<int, double> taxRates;

  /// `kb_paymentTypes.paymentType_id` → the row (mode, bank name, ...).
  final Map<int, Map<String, Object?>> paymentTypes;

  final List<VyaparPaymentLink> paymentLinks;
  final List<VyaparPaymentSplit> paymentSplits;

  /// Businesses expenses and other income, decoded from `journal_entry`.
  final List<VyaparExpense> expenses;

  /// `kb_settings` as key → value. Only a few keys carry business meaning, but
  /// the important one is `VYAPAR.GSTENABLED`, which says whether the company
  /// is GST registered — the firm profile in `kb_firms` does not.
  final Map<String, String?> settings;

  /// Non-fatal problems found while reading (missing tables in an older
  /// Vyapar version, quantities we could not interpret, ...).
  final List<String> warnings;

  List<VyaparDocument> documentsOfKind(VyaparDocKind kind) =>
      documents.where((d) => d.kind == kind).toList();

  /// How many transactions use codes this importer cannot map.
  Map<int, int> get unsupportedTypeCounts {
    final counts = <int, int>{};
    for (final doc in documents) {
      if (doc.kind != VyaparDocKind.unsupported) continue;
      counts.update(doc.txnType, (v) => v + 1, ifAbsent: () => 1);
    }
    return counts;
  }
}

/// One leg of a two-line journal entry, while it is being classified.
class _JournalSide {
  const _JournalSide({
    required this.side,
    required this.name,
    required this.amount,
  });

  /// `1` for a debit, `-1` for a credit.
  final int side;

  /// The account name, which becomes Apex Books's expense category.
  final String name;

  final double amount;
}

/// Raised when a file is not a readable Vyapar backup. The message is written
/// to be shown to the user verbatim.
class VyaparFormatException implements Exception {
  const VyaparFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

class VyaparBackupReader {
  VyaparBackupReader._();

  /// Opens [bytes] (the contents of a `.vyb`) and reads it into a snapshot.
  ///
  /// Throws [VyaparFormatException] with a user-facing message when the file is
  /// not a Vyapar backup.
  static Future<VyaparSnapshot> read(Uint8List bytes) async {
    final database = _extractDatabase(bytes);
    try {
      return _snapshot(database);
    } finally {
      database.dispose();
    }
  }

  // ---- Archive -----------------------------------------------------------

  /// Unpacks the single `.vyp` SQLite file out of the `.vyb` ZIP.
  ///
  /// The database is handed to `sqlite3`, which opens by path, so it is written
  /// to a throw-off temp directory first. The file is removed before returning.
  static Database _extractDatabase(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) {
      throw const VyaparFormatException(
        'That does not look like a Vyapar backup. Pick the .vyb file Vyapar '
        'creates from Backup & Restore.',
      );
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object {
      throw const VyaparFormatException(
        'The Vyapar backup could not be opened — the archive is damaged or '
        'incomplete. Try exporting a fresh backup from Vyapar.',
      );
    }

    final entries = archive.files.where((f) => f.isFile).toList();
    ArchiveFile? entry;
    for (final candidate in entries) {
      if (candidate.name.toLowerCase().endsWith('.vyp')) {
        entry = candidate;
        break;
      }
    }
    entry ??= entries.length == 1 ? entries.first : null;
    if (entry == null) {
      throw const VyaparFormatException(
        'The backup does not contain a Vyapar database (.vyp).',
      );
    }

    final content = entry.content as List<int>;
    if (content.length < 16 ||
        String.fromCharCodes(content.take(15)) != 'SQLite format 3') {
      throw const VyaparFormatException(
        'This Vyapar backup is not in the readable format Apex Books supports. '
        'Vyapar versions before 3 used an encrypted container.',
      );
    }

    Directory? directory;
    try {
      directory = Directory.systemTemp.createTempSync('atria_vyapar_');
      final file = File(p.join(directory.path, 'vyapar.vyp'))
        ..writeAsBytesSync(content);
      return sqlite3.open(file.path, mode: OpenMode.readOnly);
    } on Object catch (error) {
      throw VyaparFormatException(
        'The Vyapar database could not be read: $error',
      );
    } finally {
      // sqlite3 keeps its own handle on the bytes it has already mapped, so
      // deleting the file here is safe on every platform we ship.
      try {
        directory?.deleteSync(recursive: true);
      } on Object {
        // A leftover temp file is not worth failing an import over.
      }
    }
  }

  // ---- Tables ------------------------------------------------------------

  static VyaparSnapshot _snapshot(Database db) {
    final warnings = <String>[];

    if (!_tables(db).contains('kb_transactions')) {
      throw const VyaparFormatException(
        'This backup has no transactions table — it is not a Vyapar company '
        'backup.',
      );
    }

    final firmRows = _rows(db, 'kb_firms');
    final firm = firmRows.isEmpty ? <String, Object?>{} : firmRows.first;
    if (firm.isEmpty) {
      warnings.add('The backup has no company profile.');
    }

    final names = _rows(db, 'kb_names');

    final taxRates = <int, double>{};
    for (final row in _rows(db, 'kb_tax_code')) {
      final id = _int(row['tax_code_id']);
      if (id != null) taxRates[id] = _double(row['tax_rate']);
    }

    final paymentTypes = <int, Map<String, Object?>>{};
    for (final row in _rows(db, 'kb_paymentTypes')) {
      final id = _int(row['paymentType_id']);
      if (id != null) paymentTypes[id] = row;
    }

    final linesByTxn = <int, List<VyaparLine>>{};
    for (final row in _rows(db, 'kb_lineitems', orderBy: 'lineitem_id')) {
      final txnId = _int(row['lineitem_txn_id']) ?? 0;
      final lineId = _int(row['lineitem_id']) ?? 0;
      (linesByTxn[txnId] ??= <VyaparLine>[]).add(VyaparLine(
        id: lineId,
        txnId: txnId,
        sortOrder: lineId,
        itemId: _int(row['item_id']),
        unitId: _int(row['lineitem_unit_id']),
        taxId: _int(row['lineitem_tax_id']),
        quantity: _double(row['quantity']),
        price: _double(row['priceperunit']),
        total: _double(row['total_amount']),
        taxAmount: _double(row['lineitem_tax_amount']),
        discountAmount: _double(row['lineitem_discount_amount']),
        discountPercent: _double(row['lineitem_discount_percent']),
        cess: _double(row['lineitem_additional_cess']),
        description: _string(row['lineitem_description']),
      ));
    }

    final documents = <VyaparDocument>[];
    for (final row in _rows(db, 'kb_transactions', orderBy: 'txn_date, txn_id')) {
      final type = _int(row['txn_type']);
      final subType = _int(row['txn_sub_type']) ?? 0;
      documents.add(VyaparDocument(
        id: _int(row['txn_id']) ?? 0,
        kind: vyaparDocKindFor(type, subType),
        txnType: type ?? -1,
        txnSubType: subType,
        status: _int(row['txn_status']) ?? 1,
        paymentStatus: _int(row['txn_payment_status']) ?? 1,
        number: _string(row['txn_ref_number_char']),
        paymentReference: _string(row['txn_payment_reference']),
        date: _date(row['txn_date']),
        dueDate: _date(row['txn_due_date']),
        nameId: _int(row['txn_name_id']),
        balanceAmount: _double(row['txn_balance_amount']),
        cashAmount: _double(row['txn_cash_amount']),
        roundOff: _double(row['txn_round_off_amount']),
        discountAmount: _double(row['txn_discount_amount']),
        discountPercent: _double(row['txn_discount_percent']),
        taxAmount: _double(row['txn_tax_amount']),
        placeOfSupply: _string(row['txn_place_of_supply']),
        billingAddress: _string(row['txn_billing_address']),
        shippingAddress: _string(row['txn_shipping_address']),
        notes: _string(row['txn_description']),
        paymentTypeId: _int(row['txn_payment_type_id']),
        taxInclusive: (_int(row['txn_tax_inclusive']) ?? 0) == 1,
      ));
    }

    final paymentLinks = <VyaparPaymentLink>[];
    for (final row in _rows(db, 'kb_txn_links')) {
      final firstId = _int(row['txn_links_txn_1_id']);
      final secondId = _int(row['txn_links_txn_2_id']);
      final firstType = _int(row['txn_links_txn_1_type']);
      final secondType = _int(row['txn_links_txn_2_type']);
      final amount = _double(row['txn_links_amount']);
      if (firstId == null || secondId == null) continue;
      final firstIsPayment = firstType == 3 || firstType == 4;
      final secondIsPayment = secondType == 3 || secondType == 4;
      if (firstIsPayment && !secondIsPayment) {
        paymentLinks.add(VyaparPaymentLink(
          paymentTxnId: firstId,
          documentTxnId: secondId,
          amount: amount,
        ));
      } else if (secondIsPayment && !firstIsPayment) {
        paymentLinks.add(VyaparPaymentLink(
          paymentTxnId: secondId,
          documentTxnId: firstId,
          amount: amount,
        ));
      }
    }

    final settings = <String, String?>{};
    for (final row in _rows(db, 'kb_settings')) {
      final key = _string(row['setting_key']);
      if (key != null) settings[key] = _string(row['setting_value']);
    }

    final paymentSplits = <VyaparPaymentSplit>[];
    for (final row in _rows(db, 'txn_payment_mapping')) {
      final documentTxnId = _int(row['txn_id']);
      final paymentTypeId = _int(row['payment_id']);
      if (documentTxnId == null || paymentTypeId == null) continue;
      paymentSplits.add(VyaparPaymentSplit(
        paymentTypeId: paymentTypeId,
        documentTxnId: documentTxnId,
        amount: _double(row['amount']),
        reference: _string(row['payment_reference']),
      ));
    }

    return VyaparSnapshot(
      firm: firm,
      parties: names.where((n) => _int(n['name_type']) == 1).toList(),
      expenseHeads: names.where((n) => _int(n['name_type']) == 2).toList(),
      items: _rows(db, 'kb_items', orderBy: 'item_id'),
      units: _rows(db, 'kb_item_units', orderBy: 'unit_id'),
      itemCategories: _rows(db, 'kb_item_categories'),
      partyGroups: _rows(db, 'kb_party_groups'),
      documents: documents,
      linesByTxn: linesByTxn,
      taxRates: taxRates,
      paymentTypes: paymentTypes,
      paymentLinks: paymentLinks,
      paymentSplits: paymentSplits,
      expenses: _readExpenses(db, warnings),
      settings: settings,
      warnings: warnings,
    );
  }

  // ---- Expenses ----------------------------------------------------------

  /// Decodes Vyapar's journal entries into expenses and other income.
  ///
  /// Vyapar's expense module writes a `journal_entry` per expense (an expense
  /// head on one side, Cash or a bank account on the other) rather than a
  /// `kb_transactions` row, and neither that layout nor
  /// `other_accounts.account_type` is documented — so this imports an entry
  /// only when its shape is unambiguous:
  ///
  /// * exactly two lines, one debit and one credit, of equal positive amounts;
  /// * one side a Cash/bank account and the other side not;
  /// * the debit/credit side readable from `amount_type` (or a negative amount).
  ///
  /// Everything else — a transfer between two bank accounts, a multi-line
  /// adjustment, an entry whose sides cannot be told apart — is counted and
  /// reported instead of guessed at, because a misread journal entry moves
  /// money between accounts silently. A backup with no `journal_entry` table
  /// reads as no expenses, which is what older Vyapar companies are.
  static List<VyaparExpense> _readExpenses(Database db, List<String> warnings) {
    final entries = _rows(db, 'journal_entry', orderBy: 'date, id');
    if (entries.isEmpty) return const [];

    final accounts = <int, Map<String, Object?>>{};
    for (final row in _rows(db, 'other_accounts')) {
      final id = _int(row['id'] ?? row['account_id']);
      if (id != null) accounts[id] = row;
    }
    if (accounts.isEmpty) {
      warnings.add(
        'This backup keeps its expenses as journal entries but names their '
        'accounts in a way Apex Books could not read, so those expenses were left '
        'behind.',
      );
      return const [];
    }

    final linesByEntry = <int, List<Map<String, Object?>>>{};
    for (final row in _rows(db, 'journal_entry_line_items')) {
      final entryId = _int(row['journal_entry_id'] ?? row['journal_entry']);
      if (entryId == null) continue;
      (linesByEntry[entryId] ??= <Map<String, Object?>>[]).add(row);
    }

    final expenses = <VyaparExpense>[];
    var unmapped = 0;
    for (final entry in entries) {
      final id = _int(entry['id'] ?? entry['journal_entry_id']);
      if (id == null) continue;
      final lines = linesByEntry[id] ?? const <Map<String, Object?>>[];
      if (lines.length != 2) {
        unmapped++;
        continue;
      }

      final sides = <_JournalSide>[];
      for (final line in lines) {
        final account = accounts[_int(line['account_id'] ?? line['account'])];
        if (account == null) {
          sides.clear();
          break;
        }
        final raw = _double(line['amount']);
        final side = _journalSide(line['amount_type']) ?? (raw < 0 ? -1 : null);
        final name = _string(account['name']) ?? _string(account['account_name']);
        if (side == null || name == null || raw == 0) {
          sides.clear();
          break;
        }
        sides.add(_JournalSide(side: side, name: name, amount: raw.abs()));
      }
      if (sides.length != 2 ||
          sides[0].side == sides[1].side ||
          sides[0].amount <= 0 ||
          (sides[0].amount - sides[1].amount).abs() > 0.01) {
        unmapped++;
        continue;
      }

      final debit = sides[0].side == 1 ? sides[0] : sides[1];
      final credit = sides[0].side == 1 ? sides[1] : sides[0];
      final debitIsMoney = _isMoneyAccount(debit.name);
      final creditIsMoney = _isMoneyAccount(credit.name);
      if (debitIsMoney == creditIsMoney) {
        // Both sides the same kind: a transfer, or two ledgers being adjusted.
        // Real, but not an expense, and not something to guess at.
        unmapped++;
        continue;
      }

      // Money leaving a cash/bank account is an expense; money arriving is
      // other income. The side that is *not* Cash/bank is the category.
      final isExpense = creditIsMoney;
      final moneyName = isExpense ? credit.name : debit.name;
      expenses.add(VyaparExpense(
        id: id,
        type: isExpense ? 'expense' : 'income',
        reference: _string(entry['reference_number']) ?? 'VYP-JE-$id',
        date: _date(entry['date']),
        category: isExpense ? debit.name : credit.name,
        amount: debit.amount,
        mode: moneyName.toLowerCase().contains('cash') ? 'cash' : 'bank_transfer',
        notes: _string(entry['description']),
      ));
    }

    if (unmapped > 0) {
      warnings.add(
        '$unmapped journal entr${unmapped == 1 ? 'y' : 'ies'} did not look like '
        'an expense or other income (the usual cause is a transfer between two '
        'accounts, or an adjustment with more than two lines), so they were '
        'left behind rather than guessed at.',
      );
    }
    return expenses;
  }

  /// Reads a journal line's side: `1` is a debit, `-1` a credit.
  static int? _journalSide(Object? raw) {
    final text = (_string(raw) ?? '').toLowerCase();
    if (text.isEmpty) return null;
    if (text == '1' || text.startsWith('d')) return 1;
    if (text == '2' || text.startsWith('c')) return -1;
    return null;
  }

  /// Whether a ledger name is a cash or bank account.
  ///
  /// `other_accounts.account_type` is not documented and differs between Vyapar
  /// versions, so the name decides. An account Apex Books cannot recognise is *not* a
  /// money account, which keeps an unknown ledger out of the cash column.
  static bool _isMoneyAccount(String name) {
    final text = name.toLowerCase();
    if (text.contains('cash')) return true;
    const hints = ['bank', 'a/c', 'acct', 'current account', 'savings'];
    if (hints.any(text.contains)) return true;
    const banks = [
      'hdfc', 'icici', 'sbi', 'axis', 'kotak', 'idfc', 'pnb',
      'punjab national', 'bank of baroda', 'canara', 'union bank',
      'indusind', 'federal bank', 'rbl', 'bandhan', 'au small',
    ];
    return banks.any(text.contains);
  }

  // ---- Version-tolerant SQL ---------------------------------------------

  static Set<String> _tables(Database db) {
    try {
      return {
        for (final row in db.select(
            "SELECT name FROM sqlite_master WHERE type = 'table'"))
          row['name'] as String,
      };
    } on Object {
      return const {};
    }
  }

  /// Reads [table], selecting only the columns that actually exist.
  ///
  /// Vyapar's schema grows between app versions, so every read here must
  /// survive a missing column instead of throwing on it.
  static List<Map<String, Object?>> _rows(
    Database db,
    String table, {
    String? orderBy,
  }) {
    if (!_tables(db).contains(table)) return const [];
    final available = <String>{};
    for (final row in db.select('PRAGMA table_info("$table")')) {
      available.add(row['name'] as String);
    }
    if (available.isEmpty) return const [];

    final columns =
        available.map((c) => '"$c"').join(', ');
    final sql = StringBuffer('SELECT $columns FROM "$table"');
    if (orderBy != null) sql.write(' ORDER BY $orderBy');
    try {
      final result = db.select(sql.toString());
      return [
        for (final row in result)
          {for (final name in available) name: row[name]},
      ];
    } on Object {
      return const [];
    }
  }

  static String? _string(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static int? _int(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(_string(value) ?? '');
  }

  static double _double(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(_string(value) ?? '') ?? 0;
  }

  static DateTime? _date(Object? value) {
    final text = _string(value);
    if (text == null) return null;
    return DateTime.tryParse(text);
  }
}