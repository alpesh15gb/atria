import 'package:drift/drift.dart';

/// A bank account the business holds, or a cash box standing in for one.
///
/// Exists because `payments.bankAccount` is a free-text string. That is enough
/// to *record* that money went somewhere and not enough to answer the two
/// questions the Bank Statement report asks: what is the balance, and what
/// happened in this account over this window. Both need rows, not strings.
///
/// The ledger is still the source of truth for the balance — every payment
/// posts a journal line — so [currentBalance] is a cached convenience for the
/// account list, not an accounting figure. It can only disagree with the
/// ledger if a write is not atomic, which is why the two are written in one
/// transaction.
@DataClassName('BankAccountEntity')
@TableIndex(name: 'idx_bank_accounts_firm', columns: {#firmId})
class BankAccounts extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();

  /// What the shop calls it. Not the bank's official name: a counter shop
  /// running twenty accounts calls them "HDFC main" and "HDFC new", and a
  /// field that insists on the official name gets "Main Street" typed into it.
  TextColumn get name => text().withLength(min: 1, max: 120)();

  TextColumn get bankName => text().nullable()();
  TextColumn get accountNumber => text().nullable()();
  TextColumn get ifsc => text().nullable()();
  TextColumn get accountHolder => text().nullable()();
  TextColumn get branch => text().nullable()();

  /// bank | cash | upi | card
  ///
  /// `cash` is a real row and not the absence of one: "Cash in hand" has to
  /// appear in the Bank Statement report beside the bank accounts, and the
  /// only honest way to show it there is as an account.
  TextColumn get type => text().withDefault(const Constant('bank'))();

  /// Cached from the payment and journal ledger. See the class note.
  RealColumn get currentBalance => real().withDefault(const Constant(0))();

  /// The ledger account this bank feeds, so a payment can post to the right
  /// place without the operator picking an account on every entry. Null means
  /// the default cash/bank account for the firm.
  TextColumn get ledgerAccountId => text().nullable()();

  /// UPI ID for a `upi` account, which is how the QR code is addressed.
  TextColumn get upiId => text().nullable()();

  TextColumn get notes => text().nullable()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Money borrowed or lent, and the repayments against it.
///
/// Exists for "Loan Statement", which is not a party statement: a loan has a
/// schedule (principal and interest, due dates, an outstanding balance) and a
/// party statement has none of that. Modelling a loan as a party would also
/// make the interest invisible, and interest paid is an expense a report has
/// to be able to show.
///
/// [direction] is from the *business's* point of view, so `borrowed` means
/// money in and `lent` means money out. Storing it as a direction rather than
/// as a signed amount means a statement never has to guess which way round a
/// figure runs.
@DataClassName('LoanEntity')
@TableIndex(name: 'idx_loans_firm', columns: {#firmId})
@TableIndex(name: 'idx_loans_party', columns: {#partyId})
class Loans extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();

  /// borrowed | lent
  TextColumn get direction => text().withDefault(const Constant('borrowed'))();

  TextColumn get partyId => text().nullable()();
  TextColumn get partyName => text().nullable()();

  /// The amount advanced. Kept apart from the balance because the balance
  /// moves with every repayment and the principal does not — a statement that
  /// can only show the balance cannot show how much was originally lent.
  RealColumn get principalAmount => real()();

  /// Outstanding principal. A cache of the sum of this loan's repayments,
  /// never a figure anybody types.
  RealColumn get outstandingAmount => real().withDefault(const Constant(0))();

  /// Annual rate, held as a percent (18.0 means 18%) so the screen can show
  /// the number the way a bank quotes it.
  RealColumn get interestRate => real().withDefault(const Constant(0))();

  /// Simple | compound
  TextColumn get interestType => text().withDefault(const Constant('simple'))();

  RealColumn get interestAmount => real().withDefault(const Constant(0))();

  DateTimeColumn get startDate => dateTime()();
  DateTimeColumn get dueDate => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// One movement against a loan: a disbursement, a repayment, or interest.
///
/// A separate table rather than more columns on [Loans] because a loan has many
/// of them and the schedule is the report: which repayments have landed, which
/// have not, and what interest each one carried.
///
/// Interest is snapshotted onto the transaction rather than re-derived from the
/// loan's current rate. A rate renegotiated mid-term must not retroactively
/// change what a February repayment was worth, and a report that re-derives
/// interest cannot answer what was actually paid.
@DataClassName('LoanTransactionEntity')
@TableIndex(name: 'idx_loan_txn_loan', columns: {#loanId})
class LoanTransactions extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();

  TextColumn get loanId => text().customConstraint(
    'NOT NULL REFERENCES loans(id) ON DELETE CASCADE',
  )();

  /// disbursement | repayment | interest_charge | adjustment
  TextColumn get kind => text()();

  /// Principal that moved. Interest does not reduce the principal, so an
  /// interest-only repayment leaves this at zero — which is exactly what
  /// separates "paying off the loan" from "paying this month's interest".
  RealColumn get principalAmount => real().withDefault(const Constant(0))();
  RealColumn get interestAmount => real().withDefault(const Constant(0))();

  /// The full amount that left or arrived, for the statement's money column.
  RealColumn get amount => real()();

  DateTimeColumn get date => dateTime()();
  DateTimeColumn get dueDate => dateTime().nullable()();

  /// The payment this was recorded against, so a repayment made through the
  /// payments screen and one keyed here are the same event.
  TextColumn get paymentId => text().nullable()();

  TextColumn get mode => text().withDefault(const Constant('cash'))();
  TextColumn get reference => text().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// An adjustment booked against a tax period — a figure the return shows that
/// did not come from a document.
///
/// Exists for GSTR-9. That return is a reconciliation between the books and
/// the portal, and the two legitimately disagree: a payment made through an
/// agent, a credit note from a prior year, an advance-tax offset. The return
/// has to show that difference as a line. Without a table for it the only
/// honest options are to leave the return unable to reconcile, or to let
/// somebody type the adjustment into a notes field where no report can total
/// it.
///
/// The direction matters and is stored as one: `addition` raises the figure
/// the books show, `reduction` lowers it. A signed amount would read the same
/// but leave the report unable to say *which way* it moved without knowing
/// what the books said.
@DataClassName('Gstr9AdjustmentEntity')
@TableIndex(name: 'idx_gstr9_adj_firm', columns: {#firmId})
class Gstr9Adjustments extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();

  /// addition | reduction
  TextColumn get direction => text().withDefault(const Constant('addition'))();

  /// The GSTR-9 table and line this belongs to, as free text ("4.1A", "8").
  /// Free text because the schedule is fixed by the portal and hard-coding it
  /// means a schema migration every time the government renumbers something.
  TextColumn get schedule => text()();

  TextColumn get description => text()();
  RealColumn get amount => real()();
  DateTimeColumn get date => dateTime()();

  /// The financial year this adjustment belongs to, stored as the start date
  /// so it sorts and compares like every other window in the app. GSTR-9 is
  /// 1 Apr – 31 Mar and a return on the wrong window is legally wrong even when
  /// it is arithmetically perfect.
  DateTimeColumn get financialYearStart => dateTime()();

  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
