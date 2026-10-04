import 'package:drift/drift.dart';

/// A business/firm. The app supports multiple firms locally; each is a
/// separate set of books (Vyapar's "multiple business" model).
@DataClassName('FirmEntity')
class Firms extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 120)();
  TextColumn get legalName => text().nullable()();
  TextColumn get gstin => text().nullable()();
  TextColumn get pan => text().nullable()();
  TextColumn get stateCode => text().nullable()(); // GSTIN state code
  TextColumn get addressLine1 => text().nullable()();
  TextColumn get addressLine2 => text().nullable()();
  TextColumn get city => text().nullable()();
  TextColumn get pincode => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get website => text().nullable()();
  TextColumn get logoPath => text().nullable()();
  TextColumn get currencySymbol => text().withDefault(const Constant('₹'))();
  TextColumn get currencyCode => text().withDefault(const Constant('INR'))();
  TextColumn get invoicePrefix => text().withDefault(const Constant('INV'))();
  TextColumn get quotationPrefix => text().withDefault(const Constant('QT'))();
  TextColumn get salesOrderPrefix => text().withDefault(const Constant('SO'))();
  TextColumn get purchasePrefix => text().withDefault(const Constant('PUR'))();
  TextColumn get paymentInPrefix => text().withDefault(const Constant('RCPT'))();
  TextColumn get paymentOutPrefix => text().withDefault(const Constant('PMT'))();
  TextColumn get expensePrefix => text().withDefault(const Constant('EXP'))();
  TextColumn get creditNotePrefix => text().withDefault(const Constant('CN'))();
  TextColumn get debitNotePrefix => text().withDefault(const Constant('DN'))();
  TextColumn get deliveryNotePrefix => text().withDefault(const Constant('CH'))();
  TextColumn get purchaseOrderPrefix => text().withDefault(const Constant('PO'))();
  IntColumn get numberingStyle => integer().withDefault(const Constant(1))();
  IntColumn get invoiceSequencePadding => integer().withDefault(const Constant(3))();
  /// Financial year the sequences are currently counting in, as the April
  /// year, e.g. 2026 for FY 2026-27. When a document is minted for a
  /// different FY, every document sequence resets to 0 first (numbers restart
  /// each financial year, which DocumentNumbering's FY-stamped formats expect).
  IntColumn get sequenceFy => integer().nullable()();
  IntColumn get invoiceSequence => integer().withDefault(const Constant(0))();
  IntColumn get quotationSequence => integer().withDefault(const Constant(0))();
  IntColumn get salesOrderSequence => integer().withDefault(const Constant(0))();
  IntColumn get purchaseSequence => integer().withDefault(const Constant(0))();
  IntColumn get paymentInSequence => integer().withDefault(const Constant(0))();
  IntColumn get paymentOutSequence => integer().withDefault(const Constant(0))();
  IntColumn get expenseSequence => integer().withDefault(const Constant(0))();
  IntColumn get creditNoteSequence => integer().withDefault(const Constant(0))();
  IntColumn get debitNoteSequence => integer().withDefault(const Constant(0))();
  IntColumn get deliveryNoteSequence => integer().withDefault(const Constant(0))();
  IntColumn get purchaseOrderSequence => integer().withDefault(const Constant(0))();
  TextColumn get invoiceTerms => text().nullable()();
  TextColumn get invoiceNotes => text().nullable()();
  TextColumn get signatureName => text().nullable()();
  TextColumn get upiId => text().nullable()();
  TextColumn get bankName => text().nullable()();
  TextColumn get bankAccountName => text().nullable()();
  TextColumn get bankAccountNumber => text().nullable()();
  TextColumn get bankIfsc => text().nullable()();
  TextColumn get bankBranch => text().nullable()();
  BoolColumn get showBankOnInvoice => boolean().withDefault(const Constant(false))();
  BoolColumn get showQrOnInvoice => boolean().withDefault(const Constant(false))();
  RealColumn get invoiceTcsRate => real().nullable()(); // TCS % if applicable
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
