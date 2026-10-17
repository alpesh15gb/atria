import 'package:drift/drift.dart';

/// Purchase documents: bills, purchase orders, debit notes.
@DataClassName('PurchaseBillEntity')
@TableIndex(
  name: 'uq_purchase_number',
  columns: {#firmId, #docType, #number},
  unique: true,
)
@TableIndex(name: 'idx_purchase_firm_date', columns: {#firmId, #billDate})
@TableIndex(name: 'idx_purchase_party', columns: {#partyId})
class PurchaseBills extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();

  /// bill | purchase_order | debit_note
  TextColumn get docType => text().withDefault(const Constant('bill'))();
  TextColumn get number => text().withLength(min: 1, max: 40)();
  TextColumn get supplierInvoiceNumber => text().nullable()();
  TextColumn get partyId => text().nullable()();
  DateTimeColumn get billDate => dateTime()();
  DateTimeColumn get dueDate => dateTime().nullable()();

  /// draft | confirmed | cancelled
  TextColumn get status => text().withDefault(const Constant('confirmed'))();

  /// unpaid | partial | paid
  TextColumn get paymentStatus =>
      text().withDefault(const Constant('unpaid'))();
  RealColumn get paidAmount => real().withDefault(const Constant(0))();
  RealColumn get balanceDue => real().withDefault(const Constant(0))();

  TextColumn get partyName => text().nullable()();
  TextColumn get partyGstin => text().nullable()();
  TextColumn get partyGstType => text().nullable()();
  TextColumn get partyPhone => text().nullable()();
  TextColumn get billingAddress => text().nullable()();
  TextColumn get placeOfSupply => text().nullable()();
  BoolColumn get isInterState => boolean().withDefault(const Constant(false))();
  BoolColumn get reverseCharge =>
      boolean().withDefault(const Constant(false))();
  /// Snapshot at entry time: changing registration must not rewrite history.
  BoolColumn get itcEligible => boolean().withDefault(const Constant(true))();
  BoolColumn get isInwardSupplyFromUnregistered =>
      boolean().withDefault(const Constant(false))();

  RealColumn get subTotal => real().withDefault(const Constant(0))();
  RealColumn get itemDiscount => real().withDefault(const Constant(0))();
  RealColumn get invoiceDiscountPercent =>
      real().withDefault(const Constant(0))();
  RealColumn get invoiceDiscountAmount =>
      real().withDefault(const Constant(0))();
  RealColumn get shippingCharge => real().withDefault(const Constant(0))();
  RealColumn get otherCharges => real().withDefault(const Constant(0))();
  RealColumn get taxableValue => real().withDefault(const Constant(0))();
  RealColumn get cgst => real().withDefault(const Constant(0))();
  RealColumn get sgst => real().withDefault(const Constant(0))();
  RealColumn get igst => real().withDefault(const Constant(0))();
  RealColumn get cess => real().withDefault(const Constant(0))();
  RealColumn get tds => real().withDefault(const Constant(0))();

  /// The TDS percentage the deduction was worked out from, so the bill can
  /// print "TDS @ 0.1%" and the deduction can be re-derived rather than
  /// guessed from the amount.
  RealColumn get tdsRate => real().withDefault(const Constant(0))();

  /// The deductee's PAN, snapshotted onto the bill at the moment the deduction
  /// was made.
  ///
  /// Form 27EQ asks for the PAN of the person the tax was deducted *from*, and
  /// it is the number the return is filed against. It cannot be looked up later:
  /// a supplier's PAN is on their invoice, not in this database, and by filing
  /// time the invoice may have been superseded by one with different details.
  /// Reading it from `parties` at report time means the figure can change
  /// between the deduction and the return, and a 26Q filed against the wrong
  /// PAN is a notice.
  TextColumn get deducteePan => text().nullable()();

  /// The TDS section — 192, 194, 194H, 195 and the rest.
  ///
  /// Also snapshotted rather than derived, for the same reason: the section
  /// depends on what the payment was *for*, and a business can pay the same
  /// supplier under two sections in the same year.
  TextColumn get tdsSection => text().nullable()();

  /// The rate the deduction was actually worked out at, kept beside
  /// [tdsRate] so a bill that was partly exempt can say so. Free real, since
  /// the sections carry different rates and a single column would have to be
  /// the common denominator.
  RealColumn get tdsSectionRate => real().withDefault(const Constant(0))();
  RealColumn get roundOff => real().withDefault(const Constant(0))();
  RealColumn get grandTotal => real().withDefault(const Constant(0))();

  TextColumn get notes => text().nullable()();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  IntColumn get sequence => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('PurchaseBillItemEntity')
class PurchaseBillItems extends Table {
  TextColumn get id => text()();
  TextColumn get billId => text().customConstraint(
    'NOT NULL REFERENCES purchase_bills(id) ON DELETE CASCADE',
  )();
  TextColumn get itemId => text().nullable()();
  TextColumn get name => text()();
  TextColumn get hsn => text().nullable()();
  RealColumn get quantity => real()();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  RealColumn get rate => real()();
  RealColumn get discountPercent => real().withDefault(const Constant(0))();
  RealColumn get discountAmount => real().withDefault(const Constant(0))();
  RealColumn get gstRate => real().withDefault(const Constant(0))();
  RealColumn get cessRate => real().withDefault(const Constant(0))();
  TextColumn get taxMode => text().withDefault(const Constant('exclusive'))();
  RealColumn get taxableValue => real().withDefault(const Constant(0))();
  RealColumn get cgst => real().withDefault(const Constant(0))();
  RealColumn get sgst => real().withDefault(const Constant(0))();
  RealColumn get igst => real().withDefault(const Constant(0))();
  RealColumn get cessAmount => real().withDefault(const Constant(0))();
  RealColumn get total => real().withDefault(const Constant(0))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Money in / money out against a party. Links optionally to a document.
@DataClassName('PaymentEntity')
@TableIndex(name: 'idx_payments_firm_date', columns: {#firmId, #date})
@TableIndex(name: 'idx_payments_party', columns: {#partyId})
@TableIndex(name: 'idx_payments_linked', columns: {#linkedInvoiceId})
class Payments extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();

  /// payment_in | payment_out
  TextColumn get type => text()();
  TextColumn get number => text().withLength(min: 1, max: 40)();
  TextColumn get partyId => text().nullable()();
  TextColumn get partyName => text().nullable()();

  /// The payee's GSTIN, snapshotted at the time of payment.
  ///
  /// Sales documents and purchase bills both carry a party GSTIN for exactly
  /// this reason: a receipt is a tax document, and a receipt that cannot name
  /// the payee's GSTIN is not one. Null on every payment recorded before this
  /// column existed — which is correct rather than a gap, because their payee's
  /// registration cannot be reconstructed after the fact.
  TextColumn get partyGstin => text().nullable()();
  RealColumn get amount => real()();
  DateTimeColumn get date => dateTime()();
  TextColumn get mode => text().withDefault(const Constant('cash'))();
  TextColumn get reference => text().nullable()(); // UTR / cheque no.
  DateTimeColumn get clearanceDate => dateTime().nullable()();

  /// Where a cheque has got to: null for money that is not a cheque, otherwise
  /// pending | deposited | cleared | bounced.
  ///
  /// A lifecycle rather than a boolean because the three states mean different
  /// things to the books: a cheque in hand is not money (it can bounce), a
  /// deposited cheque is still not money until the bank clears it, and only a
  /// cleared one is. The bucket in the payments screen and "cash in hand" both
  /// read from here.
  TextColumn get chequeStatus => text().nullable()();
  DateTimeColumn get depositedAt => dateTime().nullable()();
  DateTimeColumn get bouncedAt => dateTime().nullable()();

  /// Why the bank returned it, in the operator's own words ("insufficient
  /// funds", "signature mismatch") — what a follow-up call is about.
  TextColumn get bounceReason => text().nullable()();
  TextColumn get linkedInvoiceId => text().nullable()();
  TextColumn get linkedInvoiceNumber => text().nullable()();
  TextColumn get bankAccount => text().nullable()();

  /// The `bank_accounts` row this payment went through.
  ///
  /// Added alongside the old free-text [bankAccount] rather than replacing it:
  /// the string is on documents already printed and in backups already taken, so
  /// discarding it would lose data nobody can get back. Both are written for a
  /// while — the id when the account is known, the string always — and the
  /// string is what an old build reads back.
  ///
  /// Null is normal and not a gap: cash and UPI payments have no bank account,
  /// and a payment keyed before accounts existed has none either.
  TextColumn get bankAccountId => text().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  IntColumn get sequence => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Business expenses and other income.
@DataClassName('ExpenseEntity')
@TableIndex(name: 'idx_expenses_firm_date', columns: {#firmId, #date})
class Expenses extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();

  /// expense | income
  TextColumn get type => text().withDefault(const Constant('expense'))();
  TextColumn get number => text().withLength(min: 1, max: 40)();
  TextColumn get category => text()();
  RealColumn get amount => real()();
  DateTimeColumn get date => dateTime()();
  TextColumn get mode => text().withDefault(const Constant('cash'))();
  TextColumn get vendorName => text().nullable()();

  /// What was bought, when it is stock.
  ///
  /// Exists for "Expense Item Report", which has to answer "what did I spend
  /// on this item" across every purchase *and* every expense. Without the link
  /// the only way to answer it is to match on a typed-in description, which is
  /// a guess — "Petrol 20 Apr" and "Petrol, 20/4" are the same expense and no
  /// string comparison knows that.
  TextColumn get itemId => text().nullable()();

  TextColumn get reference => text().nullable()();
  RealColumn get gstAmount => real().withDefault(const Constant(0))();
  BoolColumn get itcEligible => boolean().withDefault(const Constant(true))();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  IntColumn get sequence => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}
