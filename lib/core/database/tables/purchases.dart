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
  TextColumn get firmId => text().customConstraint('NOT NULL REFERENCES firms(id) ON DELETE CASCADE')();
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
  TextColumn get paymentStatus => text().withDefault(const Constant('unpaid'))();
  RealColumn get paidAmount => real().withDefault(const Constant(0))();
  RealColumn get balanceDue => real().withDefault(const Constant(0))();

  TextColumn get partyName => text().nullable()();
  TextColumn get partyGstin => text().nullable()();
  TextColumn get partyGstType => text().nullable()();
  TextColumn get partyPhone => text().nullable()();
  TextColumn get billingAddress => text().nullable()();
  TextColumn get placeOfSupply => text().nullable()();
  BoolColumn get isInterState => boolean().withDefault(const Constant(false))();
  BoolColumn get reverseCharge => boolean().withDefault(const Constant(false))();
  BoolColumn get isInwardSupplyFromUnregistered =>
      boolean().withDefault(const Constant(false))();

  RealColumn get subTotal => real().withDefault(const Constant(0))();
  RealColumn get itemDiscount => real().withDefault(const Constant(0))();
  RealColumn get invoiceDiscountPercent => real().withDefault(const Constant(0))();
  RealColumn get invoiceDiscountAmount => real().withDefault(const Constant(0))();
  RealColumn get shippingCharge => real().withDefault(const Constant(0))();
  RealColumn get otherCharges => real().withDefault(const Constant(0))();
  RealColumn get taxableValue => real().withDefault(const Constant(0))();
  RealColumn get cgst => real().withDefault(const Constant(0))();
  RealColumn get sgst => real().withDefault(const Constant(0))();
  RealColumn get igst => real().withDefault(const Constant(0))();
  RealColumn get cess => real().withDefault(const Constant(0))();
  RealColumn get tds => real().withDefault(const Constant(0))();
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
  TextColumn get billId => text().customConstraint('NOT NULL REFERENCES purchase_bills(id) ON DELETE CASCADE')();
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
  TextColumn get firmId => text().customConstraint('NOT NULL REFERENCES firms(id) ON DELETE CASCADE')();
  /// payment_in | payment_out
  TextColumn get type => text()();
  TextColumn get number => text().withLength(min: 1, max: 40)();
  TextColumn get partyId => text().nullable()();
  TextColumn get partyName => text().nullable()();
  RealColumn get amount => real()();
  DateTimeColumn get date => dateTime()();
  TextColumn get mode => text().withDefault(const Constant('cash'))();
  TextColumn get reference => text().nullable()(); // UTR / cheque no.
  DateTimeColumn get clearanceDate => dateTime().nullable()();
  TextColumn get linkedInvoiceId => text().nullable()();
  TextColumn get linkedInvoiceNumber => text().nullable()();
  TextColumn get bankAccount => text().nullable()();
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
  TextColumn get firmId => text().customConstraint('NOT NULL REFERENCES firms(id) ON DELETE CASCADE')();
  /// expense | income
  TextColumn get type => text().withDefault(const Constant('expense'))();
  TextColumn get number => text().withLength(min: 1, max: 40)();
  TextColumn get category => text()();
  RealColumn get amount => real()();
  DateTimeColumn get date => dateTime()();
  TextColumn get mode => text().withDefault(const Constant('cash'))();
  TextColumn get vendorName => text().nullable()();
  TextColumn get reference => text().nullable()();
  RealColumn get gstAmount => real().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  IntColumn get sequence => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}
