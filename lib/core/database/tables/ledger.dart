import 'package:drift/drift.dart';

/// One account in a firm's chart of accounts.
///
/// Until this existed the app had *no* chart of accounts: the P&L and the GST
/// reports were computed straight off documents, which answers "how much did I
/// sell" but cannot answer "what do I owe" or "what is the business worth" —
/// and it leaves nowhere to put the entries that are not a document at all
/// (depreciation, a partner's capital, an opening balance brought forward).
///
/// [code] is the ordering and the identity a person recognises: the seeded chart
/// uses 1000–1999 assets, 2000–2999 liabilities, 3000–3999 equity,
/// 4000–4999 income and 5000–6999 expenses, which is the range convention
/// Tally and most Indian accountants read without being told. It is unique per
/// firm, not globally.
@DataClassName('AccountEntity')
@TableIndex(
  name: 'uq_accounts_code',
  columns: {#firmId, #code},
  unique: true,
)
@TableIndex(name: 'idx_accounts_firm_type', columns: {#firmId, #type})
class Accounts extends Table {
  TextColumn get id => text()();
  TextColumn get firmId =>
      text().customConstraint('NOT NULL REFERENCES firms(id) ON DELETE CASCADE')();
  TextColumn get code => text().withLength(min: 1, max: 12)();
  TextColumn get name => text().withLength(min: 1, max: 120)();

  /// asset | liability | equity | income | expense. The five that decide which
  /// half of the balance sheet an account lands on and which way a debit moves
  /// it — everything else about an account is presentation.
  TextColumn get type => text()();

  /// The sub-group a report prints under ("Cash & bank", "Sundry debtors",
  /// "Duties & taxes", …). Free text because Indian charts differ by trade, and
  /// a fixed enum would be wrong for somebody's books.
  TextColumn get groupName => text().withDefault(const Constant(''))();

  /// A seeded account. System accounts are what the document side of the ledger
  /// posts into, so deleting one would silently orphan every invoice already
  /// written; the UI refuses instead (see LedgerRepository.deleteAccount).
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();

  /// Retired accounts stay in the chart for the entries that already reference
  /// them, and stop being offered on new ones.
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  /// Opening balance, with the side it sits on.
  RealColumn get openingBalance => real().withDefault(const Constant(0))();
  TextColumn get openingType =>
      text().withDefault(const Constant('dr'))(); // dr | cr

  TextColumn get description => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// A journal voucher: the one place an entry can be made that is not a document.
///
/// Every line must balance (see [JournalLines]); the repository enforces it on
/// save, so an unbalanced voucher cannot reach the table.
@DataClassName('JournalEntryEntity')
@TableIndex(
  name: 'uq_journal_number',
  columns: {#firmId, #number},
  unique: true,
)
@TableIndex(name: 'idx_journal_firm_date', columns: {#firmId, #date})
class JournalEntries extends Table {
  TextColumn get id => text()();
  TextColumn get firmId =>
      text().customConstraint('NOT NULL REFERENCES firms(id) ON DELETE CASCADE')();
  TextColumn get number => text().withLength(min: 1, max: 40)();
  DateTimeColumn get date => dateTime()();

  /// What the voucher is for — "Depreciation for September", "Capital
  /// introduced by the proprietor". Required, because an unexplained journal
  /// entry is the hardest thing to audit a year later.
  TextColumn get narration => text()();
  TextColumn get reference => text().nullable()();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  IntColumn get sequence => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// One debit or credit of a [JournalEntries] voucher.
///
/// Exactly one of [debit] and [credit] is non-zero: the repository rejects a
/// line that sets both, because "both" is how a doubled entry slips into a set
/// of books and only surfaces as a trial balance that will not, quite, agree.
@DataClassName('JournalLineEntity')
@TableIndex(name: 'idx_journal_lines_entry', columns: {#entryId})
@TableIndex(name: 'idx_journal_lines_account', columns: {#accountId})
class JournalLines extends Table {
  TextColumn get id => text()();
  TextColumn get entryId => text()
      .customConstraint('NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE')();
  TextColumn get accountId => text()();
  RealColumn get debit => real().withDefault(const Constant(0))();
  RealColumn get credit => real().withDefault(const Constant(0))();
  TextColumn get narration => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}
