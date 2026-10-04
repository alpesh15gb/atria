import 'dart:async';

import 'package:drift/drift.dart';

import '../../constants/payment_modes.dart';
import '../../utils/id_utils.dart';
import '../app_database.dart';
import 'repository_extensions.dart';
import 'sync_mixin.dart';

/// The codes the document side of the app posts into.
///
/// Codes rather than ids, because a code is what an accountant reads, prints
/// and reconciles against, and because a seeded chart that is rebuilt keeps its
/// meaning. The ranges follow the convention Indian accountants already read:
/// 1xxx assets, 2xxx liabilities, 3xxx equity, 4xxx income, 5xxx/6xxx expenses.
class LedgerCodes {
  LedgerCodes._();

  // Assets.
  static const cash = '1000';
  static const bank = '1010';
  static const chequesInHand = '1020';
  static const debtors = '1100';
  static const inventory = '1200';
  static const inputGst = '1300';
  static const tdsReceivable = '1310';

  // Liabilities.
  static const creditors = '2000';
  static const outputGst = '2100';
  static const tcsPayable = '2110';
  static const tdsPayable = '2120';

  // Equity.
  static const capital = '3000';
  static const drawings = '3100';
  static const retained = '3900';

  // Income.
  static const sales = '4000';
  static const salesReturns = '4100';
  static const otherIncome = '4900';

  // Expenses and the movement accounts.
  static const purchases = '5000';
  /// Where an expense category that no longer matches its account lands, so a
  /// posting is never dropped just because somebody renamed an account.
  static const otherExpenses = '6900';
  static const purchaseReturns = '5100';
  static const rounding = '5900';

  /// Where a posting lands when its account has gone missing. A visible
  /// "Suspense" balance is far better than a silently dropped posting: the
  /// trial balance still agrees and the accountant can see what happened.
  static const suspense = '5905';

  /// First code handed to an auto-created expense / other-income account.
  static const firstExpenseCode = 6001;
  static const firstIncomeCode = 4901;
}

/// The chart every firm starts with. `(code, name, type, group, system)`.
const List<(String, String, String, String, bool)> kSeedChart = [
  (LedgerCodes.cash, 'Cash in hand', 'asset', 'Cash & bank', true),
  (LedgerCodes.bank, 'Bank account', 'asset', 'Cash & bank', true),
  (LedgerCodes.chequesInHand, 'Cheques in hand', 'asset', 'Cash & bank', true),
  (LedgerCodes.debtors, 'Sundry debtors', 'asset', 'Sundry debtors', true),
  (LedgerCodes.inventory, 'Closing stock', 'asset', 'Stock in hand', true),
  (LedgerCodes.inputGst, 'Input GST credit', 'asset', 'Duties & taxes', true),
  (LedgerCodes.tdsReceivable, 'TDS receivable', 'asset', 'Duties & taxes', true),
  (LedgerCodes.creditors, 'Sundry creditors', 'liability', 'Sundry creditors', true),
  (LedgerCodes.outputGst, 'Output GST payable', 'liability', 'Duties & taxes', true),
  (LedgerCodes.tcsPayable, 'TCS payable', 'liability', 'Duties & taxes', true),
  (LedgerCodes.tdsPayable, 'TDS payable', 'liability', 'Duties & taxes', true),
  (LedgerCodes.capital, 'Capital account', 'equity', 'Capital', true),
  (LedgerCodes.drawings, "Owner's drawings", 'equity', 'Capital', true),
  (LedgerCodes.retained, 'Retained earnings', 'equity', 'Reserves', true),
  (LedgerCodes.sales, 'Sales', 'income', 'Sales', true),
  (LedgerCodes.salesReturns, 'Sales returns', 'income', 'Sales', true),
  (LedgerCodes.otherIncome, 'Other income', 'income', 'Other income', true),
  (LedgerCodes.purchases, 'Purchases', 'expense', 'Purchases', true),
  (LedgerCodes.purchaseReturns, 'Purchase returns', 'expense', 'Purchases', true),
  (LedgerCodes.otherExpenses, 'Other expenses', 'expense', 'Expenses', true),
  (LedgerCodes.rounding, 'Round off', 'expense', 'Adjustments', true),
  (LedgerCodes.suspense, 'Suspense', 'liability', 'Adjustments', true),
];

/// A draft line of a journal voucher, before it is saved.
class JournalLineDraft {
  final String accountId;
  final double debit;
  final double credit;
  final String? narration;

  const JournalLineDraft({
    required this.accountId,
    this.debit = 0,
    this.credit = 0,
    this.narration,
  });
}

/// One account's numbers over a period. [opening] and [closing] are **signed**:
/// positive is a debit balance, negative a credit balance. That single
/// convention is what lets assets, liabilities, income and expenses share one
/// report class without a per-type special case.
class LedgerAccountBalance {
  final AccountEntity account;
  final double opening;
  final double debit;
  final double credit;

  const LedgerAccountBalance({
    required this.account,
    required this.opening,
    required this.debit,
    required this.credit,
  });

  double get closing => opening + debit - credit;
  double get openingDebit => opening > 0 ? opening : 0;
  double get openingCredit => opening < 0 ? -opening : 0;
  double get closingDebit => closing > 0 ? closing : 0;
  double get closingCredit => closing < 0 ? -closing : 0;
  bool get isDr => closing >= 0;
}

/// A trial balance: every account with its opening, period movements and
/// closing balance. The report that proves the books agree.
class TrialBalance {
  final DateTime asOf;
  final DateTime? from;
  final List<LedgerAccountBalance> rows;

  const TrialBalance({required this.asOf, this.from, required this.rows});

  double get totalOpeningDebit =>
      rows.fold(0.0, (s, r) => s + r.openingDebit);
  double get totalOpeningCredit =>
      rows.fold(0.0, (s, r) => s + r.openingCredit);
  double get totalDebit => rows.fold(0.0, (s, r) => s + r.debit);
  double get totalCredit => rows.fold(0.0, (s, r) => s + r.credit);
  double get totalClosingDebit => rows.fold(0.0, (s, r) => s + r.closingDebit);
  double get totalClosingCredit =>
      rows.fold(0.0, (s, r) => s + r.closingCredit);

  /// True when closing debits equal closing credits to the paisa. Everything
  /// else in this file exists to keep this true.
  bool get isBalanced =>
      (totalClosingDebit - totalClosingCredit).abs() < 0.01;

  double get difference => totalClosingDebit - totalClosingCredit;
}

/// A heading on the balance sheet ("Cash & bank", "Duties & taxes", …) with
/// the accounts that print under it.
class BalanceSheetGroup {
  final String title;
  final String type; // 'asset' | 'liability' | 'equity'
  final List<LedgerAccountBalance> accounts;

  const BalanceSheetGroup({
    required this.title,
    required this.accounts,
    this.type = 'asset',
  });

  double get total {
    if (type == 'asset') {
      return accounts.fold(0.0, (s, a) => s + a.closing);
    }
    // For liability and equity, credit is normal balance (positive)
    return accounts.fold(0.0, (s, a) => s - a.closing);
  }
}

/// Assets, liabilities and equity as of a date, with the profit the income and
/// expense accounts have accumulated to that date folded into equity.
class BalanceSheet {
  final DateTime asOf;
  final List<BalanceSheetGroup> assets;
  final List<BalanceSheetGroup> liabilities;
  final List<BalanceSheetGroup> equity;

  /// Cumulative profit to [asOf]. Negative means a loss.
  final double netProfit;

  const BalanceSheet({
    required this.asOf,
    required this.assets,
    required this.liabilities,
    required this.equity,
    required this.netProfit,
  });

  double get totalAssets => assets.fold(0.0, (s, g) => s + g.total);
  double get totalLiabilities => liabilities.fold(0.0, (s, g) => s + g.total);
  double get totalEquity =>
      equity.fold(0.0, (s, g) => s + g.total) + netProfit;

  /// Assets less (liabilities + equity). Zero when the books agree — which,
  /// with double entry, they always do unless a posting was dropped.
  double get difference =>
      totalAssets - (totalLiabilities + totalEquity);

  bool get isBalanced => difference.abs() < 0.01;
}

/// One movement in an account's ledger.
class LedgerEntryRow {
  final DateTime date;
  final String narration;
  final String? document;
  final double debit;
  final double credit;

  /// The account's balance *after* this movement, opening included. This is
  /// what a ledger's Balance column prints, and it has to be cumulative — a
  /// row that shows `opening + this row's amount` reads as a series of
  /// unrelated figures and disagrees with the closing balance printed below
  /// it.
  final double balance;

  const LedgerEntryRow({
    required this.date,
    required this.narration,
    this.document,
    required this.debit,
    required this.credit,
    required this.balance,
  });

  double get amount => debit - credit;
}

/// A single account's ledger with a running balance.
class AccountLedger {
  final AccountEntity account;
  final double opening;
  final List<LedgerEntryRow> rows;

  const AccountLedger({
    required this.account,
    required this.opening,
    required this.rows,
  });

  double get closing =>
      rows.fold(opening, (s, r) => s + r.debit - r.credit);
  double get totalDebit => rows.fold(0.0, (s, r) => s + r.debit);
  double get totalCredit => rows.fold(0.0, (s, r) => s + r.credit);
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// A single movement with enough context to print it.
class _Row {
  final DateTime date;
  final String code;
  final double debit;
  final double credit;
  final String narration;
  final String? document;

  const _Row({
    required this.date,
    required this.code,
    required this.debit,
    required this.credit,
    required this.narration,
    this.document,
  });
}

/// Every movement the books contain, per account code, before any period
/// slicing. Built once per report so a trial balance, a balance sheet and an
/// account ledger can never disagree about what a document posted.
class _Book {
  final Map<String, AccountEntity> byCode;
  final Map<String, List<_Row>> rowsByCode;

  const _Book({required this.byCode, required this.rowsByCode});
}

class _Postings {
  final List<_Row> rows = [];

  /// Adds one movement. A negative [debit] or [credit] is folded onto the
  /// other side rather than stored as a negative number, so a report never
  /// prints "debit -500" for what is plainly a credit. [negate] swaps the two
  /// sides, which is how a credit note reverses an invoice.
  void post(
    String code, {
    required DateTime date,
    required String narration,
    String? document,
    double debit = 0,
    double credit = 0,
    bool negate = false,
  }) {
    var d = negate ? credit : debit;
    var c = negate ? debit : credit;
    if (d < 0) {
      c += -d;
      d = 0;
    }
    if (c < 0) {
      d += -c;
      c = 0;
    }
    if (d == 0 && c == 0) return;
    rows.add(_Row(
      date: date,
      code: code,
      debit: d,
      credit: c,
      narration: narration,
      document: document,
    ));
  }
}

/// Ticks once when *any* of its source streams ticks, so a report that
/// depends on several tables gets one invalidation signal rather than a
/// re-derive per table. The payloads are discarded — only the tick matters.
class _MergedStream extends Stream<void> {
  _MergedStream(this._sources);

  final List<Stream<void>> _sources;

  @override
  StreamSubscription<void> listen(
    void Function(void event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<void>(sync: true);
    final subs = <StreamSubscription<void>>[];
    void teardown() {
      for (final s in subs) {
        s.cancel();
      }
    }

    controller.onCancel = teardown;
    for (final source in _sources) {
      subs.add(source.listen(
        controller.add,
        onError: controller.addError,
        // A source finishing does not finish the merge: the other tables are
        // still live, and the books are not done until all of them are.
        cancelOnError: cancelOnError,
      ));
    }
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

/// Chart of accounts, journal vouchers, and the ledger reports built from them.
///
/// The reports read the documents this app already writes (invoices, bills,
/// receipts, expenses) and post them into accounts, then add the vouchers a
/// person keyed in by hand. Nothing is stored twice: the document tables stay
/// the source of truth, so an edited invoice changes the ledger immediately and
/// there is no posting table to drift out of step.
class LedgerRepository with SyncQueueMixin {
  LedgerRepository(this.db, this.firmId);

  @override
  final AppDatabase db;

  final String firmId;

  // ---- Chart ---------------------------------------------------------------

  /// Seeds the standard chart for this firm, creating only what is missing.
  ///
  /// Idempotent and safe to call from a report: until the chart exists there is
  /// nowhere to post, so a firm that has never opened the Ledger screen would
  /// otherwise see an empty trial balance. Returns how many accounts it added.
  Future<int> ensureChart() async {
    final existing = await allAccounts();
    final haveCode = {for (final a in existing) a.code};
    var added = 0;
    final now = DateTime.now();
    await db.transaction(() async {
      for (final seed in kSeedChart) {
        if (haveCode.contains(seed.$1)) continue;
        await db.into(db.accounts).insert(AccountsCompanion.insert(
              id: 'acc_${IdUtils.newId()}',
              firmId: firmId,
              code: seed.$1,
              name: seed.$2,
              type: seed.$3,
              groupName: Value(seed.$4),
              isSystem: Value(seed.$5),
              createdAt: Value(now),
              updatedAt: Value(now),
            ));
        added++;
      }
      // One account per expense/income category actually used, so the P&L's
      // "Salaries & Wages" and the ledger's expense grouping are the same
      // thing rather than two parallel vocabularies.
      added += await _seedCategoryAccounts(now);
    });
    return added;
  }

  Future<int> _seedCategoryAccounts(DateTime now) async {
    final expenseRows = await (db.selectOnly(db.expenses, distinct: true)
          ..addColumns([db.expenses.category])
          ..where(db.expenses.firmId.equals(firmId)))
        .get();
    final incomeRows = await (db.selectOnly(db.expenses, distinct: true)
          ..addColumns([db.expenses.category])
          ..where(db.expenses.firmId.equals(firmId) &
              db.expenses.type.equals('income')))
        .get();
    var added = 0;
    for (final r in expenseRows) {
      final id = r.read(db.expenses.category);
      if (id == null) continue;
      if (await _ensureCategoryAccount(id, 'expense', now)) added++;
    }
    for (final r in incomeRows) {
      final id = r.read(db.expenses.category);
      if (id == null) continue;
      if (await _ensureCategoryAccount(id, 'income', now)) added++;
    }
    return added;
  }

  /// The account a category posts into, seedable and looked up by name.
  Future<AccountEntity> accountForCategory(String category) async {
    final label = ExpenseCategory.byId(category)?.label ??
        IncomeCategory.byId(category)?.label ??
        category;
    final isExpense = ExpenseCategory.byId(category) != null;
    final accounts = await allAccounts();
    for (final a in accounts) {
      if (a.name.toLowerCase() == label.toLowerCase() &&
          a.type == (isExpense ? 'expense' : 'income') &&
          a.code != LedgerCodes.sales &&
          a.code != LedgerCodes.otherIncome) {
        return a;
      }
    }
    await _ensureCategoryAccount(category, isExpense ? 'expense' : 'income',
        DateTime.now());
    final again = await allAccounts();
    for (final a in again) {
      if (a.name.toLowerCase() == label.toLowerCase() &&
          a.type == (isExpense ? 'expense' : 'income') &&
          a.code != LedgerCodes.sales &&
          a.code != LedgerCodes.otherIncome) {
        return a;
      }
    }
    // A user renamed the auto-created account; fall back to the catch-all so a
    // posting is never lost.
    return (await byCode(isExpense ? LedgerCodes.purchases : LedgerCodes.sales))!;
  }

  /// Creates the account for [category] if it is not there yet. Returns true
  /// when it created one.
  Future<bool> _ensureCategoryAccount(
      String category, String type, DateTime now) async {
    final label = ExpenseCategory.byId(category)?.label ??
        IncomeCategory.byId(category)?.label ??
        category;
    final accounts = await allAccounts();
    for (final a in accounts) {
      if (a.name.toLowerCase() == label.toLowerCase() && a.type == type) {
        return false;
      }
    }
    final start =
        type == 'income' ? LedgerCodes.firstIncomeCode : LedgerCodes.firstExpenseCode;
    final used = accounts.map((a) => a.code).toSet();
    var code = start;
    while (used.contains('$code')) {
      code++;
    }
    await db.into(db.accounts).insert(AccountsCompanion.insert(
          id: 'acc_${IdUtils.newId()}',
          firmId: firmId,
          code: '$code',
          name: label,
          type: type,
          groupName: Value(type == 'income' ? 'Other income' : 'Expenses'),
          isSystem: const Value(false),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    return true;
  }

  Future<List<AccountEntity>> allAccounts({bool includeInactive = false}) async {
    final q = db.select(db.accounts)
      ..where((t) => t.firmId.equals(firmId))
      ..orderBy([(t) => OrderingTerm(expression: t.code)]);
    if (!includeInactive) q.where((t) => t.isActive.equals(true));
    return q.get();
  }

  Stream<List<AccountEntity>> watchAccounts({bool includeInactive = false}) {
    final q = db.select(db.accounts)
      ..where((t) => t.firmId.equals(firmId))
      ..orderBy([(t) => OrderingTerm(expression: t.code)]);
    if (!includeInactive) q.where((t) => t.isActive.equals(true));
    return q.watch();
  }

  Future<AccountEntity?> byCode(String code) async {
    final q = db.select(db.accounts)
      ..where((t) => t.firmId.equals(firmId) & t.code.equals(code))
      ..limit(1);
    return q.getSingleOrNull();
  }

  Future<AccountEntity?> accountById(String id) async {
    final q = db.select(db.accounts)
      ..where((t) => t.firmId.equals(firmId) & t.id.equals(id))
      ..limit(1);
    return q.getSingleOrNull();
  }

  Future<AccountEntity> createAccount({
    required String name,
    required String type,
    String? code,
    String groupName = '',
    double openingBalance = 0,
    String openingType = 'dr',
    String? description,
  }) async {
    _assertAccountType(type);
    final now = DateTime.now();
    final accounts = await allAccounts();
    final resolved = (code == null || code.trim().isEmpty)
        ? await _nextCode(type, accounts)
        : code.trim();
    if (accounts.any((a) => a.code == resolved)) {
      throw StateError('Account code $resolved is already in use.');
    }
    final id = 'acc_${IdUtils.newId()}';
    await db.into(db.accounts).insert(AccountsCompanion.insert(
          id: id,
          firmId: firmId,
          code: resolved,
          name: name.trim(),
          type: type,
          groupName: Value(groupName),
          openingBalance: Value(openingBalance),
          openingType: Value(openingType),
          description: Value(description),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await db.auditRepository.log(
      action: 'create',
      entity: 'accounts',
      firmId: firmId,
      entityId: id,
      summary: 'Created account $resolved ${name.trim()}',
    );
    await enqueue(
        firmId: firmId, entity: 'accounts', entityId: id, operation: 'insert');
    return (await accountById(id))!;
  }

  /// Renames, regroups or re-opens an account. The code is deliberately not
  /// editable once documents have posted into it.
  Future<void> updateAccount(AccountEntity account) async {
    _assertAccountType(account.type);
    await db.update(db.accounts).replace(
          account.copyWith(name: account.name.trim(), updatedAt: DateTime.now()),
        );
    await db.auditRepository.log(
      action: 'update',
      entity: 'accounts',
      firmId: firmId,
      entityId: account.id,
      summary: 'Updated account ${account.code} ${account.name}',
    );
    await enqueue(
        firmId: firmId, entity: 'accounts', entityId: account.id, operation: 'update');
  }

  /// Retires an account: it stays in the chart for the entries that reference
  /// it and stops being offered on new ones.
  Future<void> setAccountActive(String id, bool active) async {
    final account = await accountById(id);
    if (account == null) return;
    if (!active && account.isSystem) {
      throw StateError(
          '${account.name} is a system account the documents post into; it '
          'cannot be switched off.');
    }
    await (db.update(db.accounts)..where((t) => t.id.equals(id)))
        .write(AccountsCompanion(
      isActive: Value(active),
      updatedAt: Value(DateTime.now()),
    ));
    await db.auditRepository.log(
      action: active ? 'restore' : 'archive',
      entity: 'accounts',
      firmId: firmId,
      entityId: id,
      summary: '${active ? 'Reactivated' : 'Archived'} account ${account.name}',
    );
    await enqueue(
        firmId: firmId, entity: 'accounts', entityId: id, operation: 'update');
  }

  /// Deletes an account outright. Refused for system accounts and for any
  /// account a voucher already uses — deleting it would leave lines pointing at
  /// nothing, which is a corrupt set of books rather than a tidy one. Archive
  /// it instead.
  Future<void> deleteAccount(String id) async {
    final account = await accountById(id);
    if (account == null) return;
    if (account.isSystem) {
      throw StateError('${account.name} is a system account and cannot be '
          'deleted. Archive it instead.');
    }
    final used = await (db.selectOnly(db.journalLines)
          ..addColumns([db.journalLines.id.count()])
          ..where(db.journalLines.accountId.equals(id)))
        .getSingle();
    if ((used.read(db.journalLines.id.count()) ?? 0) > 0) {
      throw StateError('${account.name} is used by journal vouchers. Archive it '
          'rather than deleting it.');
    }
    await (db.delete(db.accounts)..where((t) => t.id.equals(id))).go();
    await db.auditRepository.log(
      action: 'delete',
      entity: 'accounts',
      firmId: firmId,
      entityId: id,
      summary: 'Deleted unused account ${account.name}',
    );
    await enqueue(
        firmId: firmId, entity: 'accounts', entityId: id, operation: 'delete');
  }

  void _assertAccountType(String type) {
    const valid = {'asset', 'liability', 'equity', 'income', 'expense'};
    if (!valid.contains(type)) {
      throw StateError('Unknown account type "$type".');
    }
  }

  Future<String> _nextCode(String type, List<AccountEntity> accounts) async {
    final start = switch (type) {
      'income' => 4001,
      'expense' => LedgerCodes.firstExpenseCode,
      'asset' => 1400,
      'liability' => 2200,
      _ => 3001,
    };
    final used = accounts.map((a) => a.code).toSet();
    var code = start;
    while (used.contains('$code')) {
      code++;
    }
    return '$code';
  }

  // ---- Journal vouchers ----------------------------------------------------

  /// Saves a balanced journal voucher. Throws [StateError] with a readable
  /// message when the voucher does not balance, has a lineless account, or
  /// names the same side twice — the checks a person would make on paper.
  Future<JournalEntryEntity> createJournal({
    required DateTime date,
    required String narration,
    required List<JournalLineDraft> lines,
    String? reference,
    String? createdBy,
  }) async {
    await ensureChart();
    await db.assertDateEditable(firmId, date);
    _validateLines(lines);

    final now = DateTime.now();
    final id = 'jv_${IdUtils.newId()}';
    JournalEntryEntity? entry;
    await db.transaction(() async {
      final seq = await _nextJournalSequence();
      final number = 'JV/${seq.toString().padLeft(4, '0')}';
      await db.into(db.journalEntries).insert(JournalEntriesCompanion.insert(
            id: id,
            firmId: firmId,
            number: number,
            date: date,
            narration: narration.trim(),
            reference: Value(reference),
            createdBy: Value(createdBy),
            sequence: Value(seq),
            createdAt: Value(now),
            updatedAt: Value(now),
          ));
      await _insertLines(id, lines);
      entry = await journalById(id);
    });
    await db.auditRepository.log(
      action: 'create',
      entity: 'journal_entries',
      firmId: firmId,
      entityId: id,
      summary: 'Journal ${entry?.number} — ${narration.trim()}',
    );
    await enqueue(
        firmId: firmId,
        entity: 'journal_entries',
        entityId: id,
        operation: 'insert');
    return entry!;
  }

  /// Replaces a voucher's date, narration and lines. The number stays as it was
  /// issued: renumbering an existing voucher is how two people end up with
  /// different books and the same reference.
  Future<void> updateJournal(
    String id, {
    required DateTime date,
    required String narration,
    required List<JournalLineDraft> lines,
    String? reference,
  }) async {
    await db.assertDateEditable(firmId, date);
    final existing = await journalById(id);
    if (existing != null) {
      await db.assertDateEditable(firmId, existing.date);
    }
    _validateLines(lines);
    await db.transaction(() async {
      await (db.delete(db.journalLines)..where((t) => t.entryId.equals(id))).go();
      await _insertLines(id, lines);
      await (db.update(db.journalEntries)..where((t) => t.id.equals(id)))
          .write(JournalEntriesCompanion(
        date: Value(date),
        narration: Value(narration.trim()),
        reference: Value(reference),
        updatedAt: Value(DateTime.now()),
      ));
    });
    await db.auditRepository.log(
      action: 'update',
      entity: 'journal_entries',
      firmId: firmId,
      entityId: id,
      summary: 'Updated journal ${existing?.number ?? id}',
    );
    await enqueue(
        firmId: firmId,
        entity: 'journal_entries',
        entityId: id,
        operation: 'update');
  }

  /// Bins a voucher. Vouchers are soft-deleted so the sequence stays intact and
  /// the entry can be restored — the same rule the document tables follow.
  Future<void> deleteJournal(String id) async {
    final entry = await journalById(id);
    if (entry == null) return;
    await (db.update(db.journalEntries)..where((t) => t.id.equals(id)))
        .write(JournalEntriesCompanion(
      isDeleted: const Value(true),
      deletedAt: Value(DateTime.now()),
      updatedAt: Value(DateTime.now()),
    ));
    await db.auditRepository.log(
      action: 'delete',
      entity: 'journal_entries',
      firmId: firmId,
      entityId: id,
      summary: 'Binned journal ${entry.number}',
    );
    await enqueue(
        firmId: firmId,
        entity: 'journal_entries',
        entityId: id,
        operation: 'delete');
  }

  Future<void> restoreJournal(String id) async {
    await (db.update(db.journalEntries)..where((t) => t.id.equals(id)))
        .write(JournalEntriesCompanion(
      isDeleted: const Value(false),
      deletedAt: const Value(null),
      updatedAt: Value(DateTime.now()),
    ));
    await db.auditRepository.log(
      action: 'restore',
      entity: 'journal_entries',
      firmId: firmId,
      entityId: id,
      summary: 'Restored a binned journal voucher',
    );
    await enqueue(
        firmId: firmId,
        entity: 'journal_entries',
        entityId: id,
        operation: 'update');
  }

  Future<int> _nextJournalSequence() async {
    final row = await (db.selectOnly(db.journalEntries)
          ..addColumns([db.journalEntries.sequence.max()])
          ..where(db.journalEntries.firmId.equals(firmId)))
        .getSingle();
    final max = row.read(db.journalEntries.sequence.max()) ?? 0;
    return max + 1;
  }

  void _validateLines(List<JournalLineDraft> lines) {
    if (lines.length < 2) {
      throw StateError('A journal voucher needs at least two lines.');
    }
    var debit = 0.0;
    var credit = 0.0;
    for (final l in lines) {
      if (l.debit > 0 && l.credit > 0) {
        throw StateError('A line cannot be a debit and a credit at once.');
      }
      if (l.debit <= 0 && l.credit <= 0) {
        throw StateError('Every line needs an amount.');
      }
      debit += l.debit;
      credit += l.credit;
    }
    if ((debit - credit).abs() > 0.005) {
      throw StateError('The voucher does not balance: debits are '
          '${debit.toStringAsFixed(2)} and credits ${credit.toStringAsFixed(2)}.');
    }
  }

  Future<void> _insertLines(String entryId, List<JournalLineDraft> lines) async {
    var order = 0;
    for (final l in lines) {
      final id = 'jvl_${IdUtils.newId()}';
      await db.into(db.journalLines).insert(JournalLinesCompanion.insert(
            id: id,
            entryId: entryId,
            accountId: l.accountId,
            debit: Value(l.debit),
            credit: Value(l.credit),
            narration: Value(l.narration),
            sortOrder: Value(order++),
          ));
      await enqueue(
          firmId: firmId,
          entity: 'journal_lines',
          entityId: id,
          operation: 'insert');
    }
  }

  Future<JournalEntryEntity?> journalById(String id) async {
    final q = db.select(db.journalEntries)
      ..where((t) => t.firmId.equals(firmId) & t.id.equals(id))
      ..limit(1);
    return q.getSingleOrNull();
  }

  Future<List<JournalLineEntity>> journalLinesOf(String entryId) async {
    final q = db.select(db.journalLines)
      ..where((t) => t.entryId.equals(entryId))
      ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]);
    return q.get();
  }

  Stream<List<JournalEntryEntity>> watchJournals({
    bool includeDeleted = false,
    String search = '',
  }) {
    final q = db.select(db.journalEntries)
      ..where((t) => t.firmId.equals(firmId));
    if (!includeDeleted) q.where((t) => t.isDeleted.equals(false));
    if (search.trim().isNotEmpty) {
      final s = '%${search.trim().toLowerCase()}%';
      q.where((t) =>
          t.narration.lower().like(s) | t.number.lower().like(s));
    }
    q.orderBy([
      (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc),
      (t) => OrderingTerm(expression: t.sequence, mode: OrderingMode.desc),
    ]);
    return q.watch();
  }

  Future<List<JournalEntryEntity>> journals({bool includeDeleted = false}) async {
    final q = db.select(db.journalEntries)
      ..where((t) => t.firmId.equals(firmId))
      ..orderBy([
        (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.sequence, mode: OrderingMode.desc),
      ]);
    if (!includeDeleted) q.where((t) => t.isDeleted.equals(false));
    return q.get();
  }

  /// Emits whenever any table the books are built from changes, the rows
  /// discarded — only the tick matters.
  ///
  /// The reports are all derived ([_book] re-reads the documents each call),
  /// so nothing keeps them fresh on its own. A balance shown on screen has to
  /// be recomputed when a document moves, and this is the signal for that.
  /// Listening to the payments table alone would miss a cash expense; this
  /// ticks on every table that can post a movement.
  Stream<void> watchBookMovement() {
    // Written out rather than looped over a list of tables: the tables are
    // different generated types, and a loop loses the per-table type the
    // `where` clause needs to see `firmId`.
    final sources = <Stream<void>>[
      (db.select(db.salesInvoices)
            ..where((t) => t.firmId.equals(firmId))
            ..limit(1))
          .watch(),
      (db.select(db.purchaseBills)
            ..where((t) => t.firmId.equals(firmId))
            ..limit(1))
          .watch(),
      (db.select(db.payments)
            ..where((t) => t.firmId.equals(firmId))
            ..limit(1))
          .watch(),
      (db.select(db.expenses)
            ..where((t) => t.firmId.equals(firmId))
            ..limit(1))
          .watch(),
      (db.select(db.journalEntries)
            ..where((t) => t.firmId.equals(firmId))
            ..limit(1))
          .watch(),
      (db.select(db.parties)
            ..where((t) => t.firmId.equals(firmId))
            ..limit(1))
          .watch(),
      (db.select(db.accounts)
            ..where((t) => t.firmId.equals(firmId))
            ..limit(1))
          .watch(),
    ];
    return _MergedStream(sources);
  }

  /// Total of the vouchers in a period. Used by the ledger screen's header and
  /// by tests that assert a voucher reached the books.
  Future<int> journalCount({bool includeDeleted = false}) async {
    final q = db.selectOnly(db.journalEntries)
      ..addColumns([db.journalEntries.id.count()])
      ..where(db.journalEntries.firmId.equals(firmId));
    if (!includeDeleted) {
      q.where(db.journalEntries.isDeleted.equals(false));
    }
    final row = await q.getSingle();
    return row.read(db.journalEntries.id.count()) ?? 0;
  }

  // ---- Posting the documents ----------------------------------------------

  /// Every movement in the books to [asOf], ready to be sliced by period.
  Future<_Book> _book({required DateTime asOf}) async {
    final end = DateTime(asOf.year, asOf.month, asOf.day, 23, 59, 59);
    // Archived accounts stay in the books: archiving retires an account from
    // the picker, it does not erase its opening balance or its history (see
    // [setAccountActive]'s contract, and the delete dialog that sends users
    // here for exactly that reason). Loading only active rows would drop the
    // opening balance with no contra — throwing the trial balance out by that
    // amount — and would re-post the account's movements to Suspense.
    final accounts = await allAccounts(includeInactive: true);
    final byCode = {for (final a in accounts) a.code: a};
    final byId = {for (final a in accounts) a.id: a};
    final p = _Postings();

    // Quotations, orders and delivery notes are not transactions, and a
    // cancelled document never happened. Both rules match the P&L and the GST
    // returns, so the reports agree with each other.
    final invoices = await (db.select(db.salesInvoices)
          ..where((t) =>
              t.firmId.equals(firmId) &
              t.isDeleted.equals(false) &
              t.docType.isIn(['invoice', 'credit_note']) &
              t.status.equals('cancelled').not() &
              t.invoiceDate.isSmallerOrEqualValue(end)))
        .get();
    for (final d in invoices) {
      _postSale(p, d);
    }

    final bills = await (db.select(db.purchaseBills)
          ..where((t) =>
              t.firmId.equals(firmId) &
              t.isDeleted.equals(false) &
              t.docType.isIn(['bill', 'debit_note']) &
              t.status.equals('cancelled').not() &
              t.billDate.isSmallerOrEqualValue(end)))
        .get();
    for (final d in bills) {
      _postPurchase(p, d);
    }

    final payments = await (db.select(db.payments)
          ..where((t) =>
              t.firmId.equals(firmId) &
              t.isDeleted.equals(false) &
              // A bounced cheque is money that never arrived — the payment
              // repository already stops it settling its document, so the
              // ledger has to agree or the books show a phantom asset in
              // Cheques in hand against a receivable that is still owed.
              // The `isNull() |` matters: a cash/bank payment has a null
              // status, and `not(equals(...))` on a null is null in SQL,
              // which would silently drop every non-cheque payment too.
              (t.chequeStatus.isNull() |
                  t.chequeStatus.equals('bounced').not()) &
              t.date.isSmallerOrEqualValue(end)))
        .get();
    for (final pay in payments) {
      _postPayment(p, pay);
    }

    final expenses = await (db.select(db.expenses)
          ..where((t) =>
              t.firmId.equals(firmId) &
              t.isDeleted.equals(false) &
              t.date.isSmallerOrEqualValue(end)))
        .get();
    for (final e in expenses) {
      _postExpense(p, e, byCode);
    }

    // Hand-keyed vouchers, over the top of the documents.
    final entries = await (db.select(db.journalEntries)
          ..where((t) =>
              t.firmId.equals(firmId) &
              t.isDeleted.equals(false) &
              t.date.isSmallerOrEqualValue(end)))
        .get();
    for (final chunk in _chunks(entries.map((e) => e.id).toList(), 400)) {
      final lines = await (db.select(db.journalLines)
            ..where((t) => t.entryId.isIn(chunk)))
          .get();
      for (final line in lines) {
        final entry =
            entries.firstWhere((e) => e.id == line.entryId);
        final account = byId[line.accountId];
        p.post(
          account?.code ?? LedgerCodes.suspense,
          date: entry.date,
          narration: line.narration?.trim().isNotEmpty == true
              ? line.narration!.trim()
              : entry.narration,
          document: entry.number,
          debit: line.debit,
          credit: line.credit,
        );
      }
    }

    // Party opening balances. `outstandingFor` and the party statement both
    // count a party's opening, so the books have to count it too — without
    // this, Sundry debtors disagrees with the sum of the customer statements
    // by exactly the openings, on the first day and every day after.
    //
    // It is derived here rather than written as a voucher at party-save time
    // for the same reason everything else in [_book] is: a voucher would go
    // stale the moment a party's opening is edited, and would be orphaned
    // (but still on the books) when the party is purged. The party row is the
    // source of truth; the books are a view of it.
    //
    // The contra is capital, which is where an opening balance sheet's
    // balancing figure lives — the same account `createAccount`'s callers put
    // their own openings against.
    final parties = await (db.select(db.parties)
          ..where((t) =>
              t.firmId.equals(firmId) &
              t.isDeleted.equals(false) &
              t.openingBalance.isBiggerThanValue(0)))
        .get();
    for (final party in parties) {
      final isDr = party.openingBalanceType != 'cr';
      p.post(
        isDr ? LedgerCodes.debtors : LedgerCodes.creditors,
        date: party.createdAt,
        narration: 'Opening balance - ${party.name}',
        debit: isDr ? party.openingBalance : 0,
        credit: isDr ? 0 : party.openingBalance,
      );
      p.post(
        LedgerCodes.capital,
        date: party.createdAt,
        narration: 'Opening balance - ${party.name}',
        debit: isDr ? 0 : party.openingBalance,
        credit: isDr ? party.openingBalance : 0,
      );
    }

    final rowsByCode = <String, List<_Row>>{};
    for (final row in p.rows) {
      (rowsByCode[row.code] ??= []).add(row);
    }
    for (final list in rowsByCode.values) {
      list.sort((a, b) {
        final byDate = a.date.compareTo(b.date);
        if (byDate != 0) return byDate;
        return (a.document ?? '').compareTo(b.document ?? '');
      });
    }
    return _Book(byCode: byCode, rowsByCode: rowsByCode);
  }

  /// A sales invoice credits what the business earned and debits what it is
  /// owed. A credit note posts the exact mirror, into the returns account,
  /// rather than a negative sale — which is how a return reads on a P&L and on
  /// a GST return.
  void _postSale(_Postings p, SalesInvoiceEntity d) {
    final negate = d.docType == 'credit_note';
    final revenue = negate ? LedgerCodes.salesReturns : LedgerCodes.sales;
    final tax = d.cgst + d.sgst + d.igst + d.cess;
    final narration = '${negate ? 'Credit note' : 'Invoice'} ${d.number}'
        '${d.partyName == null ? '' : ' - ${d.partyName}'}';
    // Shipping is charged to the customer but is not consideration for the
    // goods, so it sits with revenue rather than inside the taxable value. The
    // same split the GST engine makes.
    final consideration = d.taxableValue + d.shippingCharge;
    p.post(LedgerCodes.debtors,
        date: d.invoiceDate,
        narration: narration,
        document: d.number,
        debit: d.grandTotal,
        negate: negate);
    p.post(revenue,
        date: d.invoiceDate,
        narration: narration,
        document: d.number,
        credit: consideration,
        negate: negate);
    p.post(LedgerCodes.outputGst,
        date: d.invoiceDate,
        narration: narration,
        document: d.number,
        credit: tax,
        negate: negate);
    p.post(LedgerCodes.tcsPayable,
        date: d.invoiceDate,
        narration: narration,
        document: d.number,
        credit: d.tcs,
        negate: negate);
    p.post(LedgerCodes.rounding,
        date: d.invoiceDate,
        narration: narration,
        document: d.number,
        credit: d.roundOff,
        negate: negate);
  }

  /// A purchase bill debits the cost and input tax, credits the supplier, and
  /// credits TDS payable for what the firm withheld and now owes the government.
  /// A debit note mirrors it into the returns account.
  void _postPurchase(_Postings p, PurchaseBillEntity d) {
    final negate = d.docType == 'debit_note';
    final cost = negate ? LedgerCodes.purchaseReturns : LedgerCodes.purchases;
    final tax = d.cgst + d.sgst + d.igst + d.cess;
    final narration = '${negate ? 'Debit note' : 'Bill'} ${d.number}'
        '${d.partyName == null ? '' : ' - ${d.partyName}'}';
    // Freight and other charges on an inward bill are part of what the goods
    // cost, so they ride with the purchase rather than with expenses.
    final landed = d.taxableValue + d.shippingCharge + d.otherCharges;
    p.post(cost,
        date: d.billDate,
        narration: narration,
        document: d.number,
        debit: landed,
        negate: negate);
    p.post(LedgerCodes.inputGst,
        date: d.billDate,
        narration: narration,
        document: d.number,
        debit: tax,
        negate: negate);
    p.post(LedgerCodes.tdsPayable,
        date: d.billDate,
        narration: narration,
        document: d.number,
        credit: d.tds,
        negate: negate);
    p.post(LedgerCodes.rounding,
        date: d.billDate,
        narration: narration,
        document: d.number,
        debit: d.roundOff,
        negate: negate);
    p.post(LedgerCodes.creditors,
        date: d.billDate,
        narration: narration,
        document: d.number,
        credit: d.grandTotal,
        negate: negate);
  }

  void _postPayment(_Postings p, PaymentEntity pay) {
    final isIn = pay.type == 'payment_in';
    final isCheque = pay.mode == 'cheque' && pay.chequeStatus != 'cleared';
    final money = pay.mode == 'cash'
        ? LedgerCodes.cash
        : (isCheque ? LedgerCodes.chequesInHand : LedgerCodes.bank);
    final narration = isIn
        ? 'Receipt ${pay.number}${pay.partyName == null ? '' : ' - ${pay.partyName}'}'
        : 'Payment ${pay.number}${pay.partyName == null ? '' : ' - ${pay.partyName}'}';
    p.post(money,
        date: pay.date,
        narration: narration,
        document: pay.number,
        debit: isIn ? pay.amount : 0,
        credit: isIn ? 0 : pay.amount);
    p.post(isIn ? LedgerCodes.debtors : LedgerCodes.creditors,
        date: pay.date,
        narration: narration,
        document: pay.number,
        debit: isIn ? 0 : pay.amount,
        credit: isIn ? pay.amount : 0);
  }

  /// An expense is money out and a cost; the GST inside it is input credit and
  /// not a cost, which is exactly the line the old reports were missing.
  void _postExpense(
    _Postings p,
    ExpenseEntity e,
    Map<String, AccountEntity> byCode,
  ) {
    final isIncome = e.type == 'income';
    final gst = e.gstAmount.clamp(0, e.amount).toDouble();
    final net = e.amount - gst;
    final money = e.mode == 'cash' ? LedgerCodes.cash : LedgerCodes.bank;
    final account = _categoryCode(e.category, byCode);
    final narration = '${isIncome ? 'Income' : 'Expense'} ${e.number}'
        '${e.vendorName == null ? '' : ' - ${e.vendorName}'}';
    if (isIncome) {
      p.post(money,
          date: e.date,
          narration: narration,
          document: e.number,
          debit: e.amount);
      p.post(account,
          date: e.date,
          narration: narration,
          document: e.number,
          credit: net);
      p.post(LedgerCodes.outputGst,
          date: e.date,
          narration: narration,
          document: e.number,
          credit: gst);
    } else {
      p.post(account,
          date: e.date,
          narration: narration,
          document: e.number,
          debit: net);
      p.post(LedgerCodes.inputGst,
          date: e.date,
          narration: narration,
          document: e.number,
          debit: gst);
      p.post(money,
          date: e.date,
          narration: narration,
          document: e.number,
          credit: e.amount);
    }
  }

  /// The code for an expense/income category, from the chart when it is there
  /// and the catch-all when the user has renamed the account behind it.
  String _categoryCode(String category, Map<String, AccountEntity> byCode) {
    final label = ExpenseCategory.byId(category)?.label ??
        IncomeCategory.byId(category)?.label ??
        category;
    for (final a in byCode.values) {
      if (a.name.toLowerCase() == label.toLowerCase()) return a.code;
    }
    final isExpense = ExpenseCategory.byId(category) != null;
    return isExpense ? LedgerCodes.otherExpenses : LedgerCodes.otherIncome;
  }

  static Iterable<List<T>> _chunks<T>(List<T> items, int size) sync* {
    for (var i = 0; i < items.length; i += size) {
      yield items.sublist(i, i + size > items.length ? items.length : i + size);
    }
  }

  // ---- Reports -------------------------------------------------------------

  /// Trial balance as of [asOf], with [from] splitting opening from period
  /// movements. Pass [from] null for a cumulative view.
  Future<TrialBalance> trialBalance({
    required DateTime asOf,
    DateTime? from,
  }) async {
    await ensureChart();
    final book = await _book(asOf: asOf);
    final rows = <LedgerAccountBalance>[];
    for (final account in book.byCode.values) {
      final movements = book.rowsByCode[account.code] ?? const <_Row>[];
      var opening = account.openingType == 'cr'
          ? -account.openingBalance
          : account.openingBalance;
      var debit = 0.0;
      var credit = 0.0;
      for (final m in movements) {
        if (from != null && m.date.isBefore(from)) {
          opening += m.debit - m.credit;
          continue;
        }
        debit += m.debit;
        credit += m.credit;
      }
      if (opening == 0 && debit == 0 && credit == 0) continue;
      rows.add(LedgerAccountBalance(
        account: account,
        opening: opening,
        debit: debit,
        credit: credit,
      ));
    }
    rows.sort((a, b) => a.account.code.compareTo(b.account.code));
    return TrialBalance(asOf: asOf, from: from, rows: rows);
  }

  /// A single account's ledger, with the balance carried in from before [from].
  Future<AccountLedger> accountLedger(
    String accountId, {
    DateTime? from,
    required DateTime asOf,
  }) async {
    await ensureChart();
    final book = await _book(asOf: asOf);
    final account = await accountById(accountId);
    if (account == null) {
      throw StateError('That account no longer exists.');
    }
    final movements = book.rowsByCode[account.code] ?? const <_Row>[];
    var opening = account.openingType == 'cr'
        ? -account.openingBalance
        : account.openingBalance;
    // `opening` is what the caller prints as the period's opening balance, so
    // it must stop at the first row in range. `running` is the balance as the
    // rows accumulate; it is a separate variable because `closing` is derived
    // from `opening` + the rows and would double-count if one fed the other.
    var running = opening;
    final rows = <LedgerEntryRow>[];
    for (final m in movements) {
      if (from != null && m.date.isBefore(from)) {
        opening += m.debit - m.credit;
        running = opening;
        continue;
      }
      running += m.debit - m.credit;
      rows.add(LedgerEntryRow(
        date: m.date,
        narration: m.narration,
        document: m.document,
        debit: m.debit,
        credit: m.credit,
        balance: running,
      ));
    }
    return AccountLedger(account: account, opening: opening, rows: rows);
  }

  /// Balance sheet as of [asOf], grouped the way a printed one reads. The
  /// profit the income and expense accounts have accumulated sits in equity, so
  /// the sheet balances without a year-end close to move it there.
  Future<BalanceSheet> balanceSheet({required DateTime asOf}) async {
    final tb = await trialBalance(asOf: asOf);
    final assetAccounts = <LedgerAccountBalance>[];
    final liabilityAccounts = <LedgerAccountBalance>[];
    final equityAccounts = <LedgerAccountBalance>[];
    var netProfit = 0.0;

    for (final row in tb.rows) {
      switch (row.account.type) {
        case 'asset':
          if (row.closing.abs() > 0.004) assetAccounts.add(row);
          break;
        case 'liability':
          if (row.closing.abs() > 0.004) liabilityAccounts.add(row);
          break;
        case 'equity':
          if (row.closing.abs() > 0.004) equityAccounts.add(row);
          break;
        case 'income':
          netProfit += -row.closing; // a credit balance is income
          break;
        case 'expense':
          netProfit -= row.closing; // a debit balance is a cost
          break;
      }
    }

    return BalanceSheet(
      asOf: asOf,
      assets: _group(assetAccounts, 'asset'),
      liabilities: _group(liabilityAccounts, 'liability'),
      equity: _group(equityAccounts, 'equity'),
      netProfit: netProfit,
    );
  }

  List<BalanceSheetGroup> _group(List<LedgerAccountBalance> rows, String type) {
    final byGroup = <String, List<LedgerAccountBalance>>{};
    for (final r in rows) {
      final key = r.account.groupName.isEmpty ? r.account.type : r.account.groupName;
      (byGroup[key] ??= []).add(r);
    }
    final titles = byGroup.keys.toList()..sort();
    return [
      for (final t in titles)
        BalanceSheetGroup(title: t, accounts: byGroup[t]!, type: type),
    ];
  }

  /// Input tax credit the firm has paid on expenses.
  ///
  /// The GST summary used to compute input credit from purchase bills alone, so
  /// the GST inside a rent or software bill was silently left out of GST
  /// payable. This is the missing half; the amount is a component of the
  /// expense total, not an extra.
  Future<double> inputTaxFromExpenses({
    DateTime? from,
    required DateTime to,
  }) async {
    final q = db.select(db.expenses)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.isDeleted.equals(false) &
          t.type.equals('expense') &
          t.gstAmount.isBiggerThanValue(0) &
          t.date.isSmallerOrEqualValue(DateTime(to.year, to.month, to.day, 23, 59, 59)));
    if (from != null) q.where((t) => t.date.isBiggerOrEqualValue(from));
    var total = 0.0;
    for (final e in await q.get()) {
      total += e.gstAmount.clamp(0, e.amount).toDouble();
    }
    return total;
  }

  /// Output tax collected on income other than sales (interest, commission,
  /// asset sale). Small, but it belongs in the same return as everything else.
  Future<double> outputTaxFromIncome({
    DateTime? from,
    required DateTime to,
  }) async {
    final q = db.select(db.expenses)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.isDeleted.equals(false) &
          t.type.equals('income') &
          t.gstAmount.isBiggerThanValue(0) &
          t.date.isSmallerOrEqualValue(DateTime(to.year, to.month, to.day, 23, 59, 59)));
    if (from != null) q.where((t) => t.date.isBiggerOrEqualValue(from));
    var total = 0.0;
    for (final e in await q.get()) {
      total += e.gstAmount.clamp(0, e.amount).toDouble();
    }
    return total;
  }
}
