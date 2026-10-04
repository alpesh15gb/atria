import 'package:drift/drift.dart';

/// Sales documents: invoices, quotations, sales orders, delivery notes.
/// Kept in one table and distinguished by [docType] so reports and numbering
/// stay consistent — the same pattern Vyapar uses.
@DataClassName('SalesInvoiceEntity')
@TableIndex(
  name: 'uq_sales_number',
  columns: {#firmId, #docType, #number},
  unique: true,
)
@TableIndex(name: 'idx_sales_firm_date', columns: {#firmId, #invoiceDate})
@TableIndex(name: 'idx_sales_party', columns: {#partyId})
class SalesInvoices extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();

  /// invoice | quotation | sales_order | delivery_note | credit_note
  TextColumn get docType => text().withDefault(const Constant('invoice'))();
  TextColumn get number => text().withLength(min: 1, max: 40)();
  TextColumn get partyId => text().nullable()();
  DateTimeColumn get invoiceDate => dateTime()();
  DateTimeColumn get dueDate => dateTime().nullable()();

  /// draft | confirmed | delivered | sent | accepted | rejected | cancelled
  ///
  /// The lifecycle only. Conversion used to overwrite this with 'converted',
  /// which destroyed the original value — the column could then not also say
  /// "expired", and `markCancelled` on a converted quotation silently
  /// un-converted it. Conversion is now [convertedToInvoiceId] instead, so
  /// this column is free to keep meaning one thing.
  TextColumn get status => text().withDefault(const Constant('confirmed'))();

  /// The invoice this document became, once converted. Null until then.
  ///
  /// This is the record that was missing: `markConverted` set a flag and threw
  /// away which invoice it became, so a converted quotation could only ever be
  /// shown as a badge with no way to open what it turned into.
  TextColumn get convertedToInvoiceId => text().nullable()();

  /// When the conversion happened — the date of the link, not the invoice date.
  DateTimeColumn get convertedAt => dateTime().nullable()();

  /// unpaid | partial | paid
  TextColumn get paymentStatus =>
      text().withDefault(const Constant('unpaid'))();
  RealColumn get paidAmount => real().withDefault(const Constant(0))();
  RealColumn get balanceDue => real().withDefault(const Constant(0))();

  // Party snapshot (denormalized for a stable historical record).
  TextColumn get partyName => text().nullable()();
  TextColumn get partyGstin => text().nullable()();
  TextColumn get partyGstType => text().nullable()();
  TextColumn get partyPhone => text().nullable()();
  TextColumn get billingAddress => text().nullable()();
  TextColumn get shippingAddress => text().nullable()();
  TextColumn get placeOfSupply => text().nullable()(); // state code
  BoolColumn get isInterState => boolean().withDefault(const Constant(false))();
  BoolColumn get reverseCharge =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isExport => boolean().withDefault(const Constant(false))();
  TextColumn get exportType =>
      text().nullable()(); // wp | wop (with/without payment)

  // Totals (stored so reports avoid re-aggregation).
  RealColumn get subTotal => real().withDefault(const Constant(0))();
  RealColumn get itemDiscount => real().withDefault(const Constant(0))();
  RealColumn get invoiceDiscountPercent =>
      real().withDefault(const Constant(0))();
  RealColumn get invoiceDiscountAmount =>
      real().withDefault(const Constant(0))();
  RealColumn get shippingCharge => real().withDefault(const Constant(0))();
  RealColumn get taxableValue => real().withDefault(const Constant(0))();
  RealColumn get cgst => real().withDefault(const Constant(0))();
  RealColumn get sgst => real().withDefault(const Constant(0))();
  RealColumn get igst => real().withDefault(const Constant(0))();
  RealColumn get cess => real().withDefault(const Constant(0))();
  RealColumn get tcs => real().withDefault(const Constant(0))();

  /// The TCS percentage the amount was worked out from, so the invoice and the
  /// return can print "TCS @ 0.1%" rather than an unattributed number. Null (or
  /// zero) means no tax was collected at source on this document.
  RealColumn get tcsRate => real().withDefault(const Constant(0))();
  RealColumn get roundOff => real().withDefault(const Constant(0))();
  RealColumn get grandTotal => real().withDefault(const Constant(0))();

  TextColumn get notes => text().nullable()();
  TextColumn get terms => text().nullable()();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  IntColumn get sequence => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Line items for [SalesInvoices].
@DataClassName('SalesInvoiceItemEntity')
class SalesInvoiceItems extends Table {
  TextColumn get id => text()();
  TextColumn get invoiceId => text().customConstraint(
    'NOT NULL REFERENCES sales_invoices(id) ON DELETE CASCADE',
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

  /// exclusive | inclusive
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
