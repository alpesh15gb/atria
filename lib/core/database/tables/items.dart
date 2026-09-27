import 'package:drift/drift.dart';

/// Products, goods and services.
///
/// [stockType]: tracked | untracked. Services are usually untracked.
/// [currentStock] is a cached running balance, kept in sync via
/// [StockMovements] for auditability.
@DataClassName('ItemEntity')
@TableIndex(name: 'idx_items_firm_name', columns: {#firmId, #name})
class Items extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint('NOT NULL REFERENCES firms(id) ON DELETE CASCADE')();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get sku => text().nullable()();
  TextColumn get hsn => text().nullable()(); // HSN for goods, SAC for services
  TextColumn get categoryId => text().nullable()();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  RealColumn get salePrice => real().withDefault(const Constant(0))();
  RealColumn get purchasePrice => real().withDefault(const Constant(0))();
  RealColumn get wholesalePrice => real().nullable()();
  RealColumn get mrp => real().nullable()();
  RealColumn get gstRate => real().withDefault(const Constant(0))();
  RealColumn get cessRate => real().withDefault(const Constant(0))();
  /// exclusive | inclusive
  TextColumn get taxMode => text().withDefault(const Constant('exclusive'))();
  BoolColumn get isService => boolean().withDefault(const Constant(false))();
  /// tracked | untracked
  TextColumn get stockType => text().withDefault(const Constant('tracked'))();
  RealColumn get openingStock => real().withDefault(const Constant(0))();
  RealColumn get currentStock => real().withDefault(const Constant(0))();
  RealColumn get lowStockAlert => real().withDefault(const Constant(0))();
  TextColumn get barcode => text().nullable()();
  TextColumn get description => text().nullable()();
  RealColumn get weightPerUnit => real().nullable()();
  /// Soft-delete flag for the recycle bin; hard delete only from there.
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Immutable stock ledger. Every movement is recorded; the item's
/// [currentStock] is a cache derived from this log.
@DataClassName('StockMovementEntity')
@TableIndex(name: 'idx_movements_firm_date', columns: {#firmId, #date})
@TableIndex(name: 'idx_movements_item', columns: {#itemId})
@TableIndex(name: 'idx_movements_source', columns: {#sourceId})
class StockMovements extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text()();
  TextColumn get itemId => text()();
  /// opening | sale | purchase | sale_return | purchase_return | adjustment
  TextColumn get kind => text()();
  RealColumn get quantity => real()(); // signed
  RealColumn get balanceAfter => real().withDefault(const Constant(0))();
  /// sales_invoices | purchase_bills | manual | opening_balance
  TextColumn get source => text()();
  TextColumn get sourceId => text().nullable()();
  TextColumn get sourceNumber => text().nullable()();
  DateTimeColumn get date => dateTime()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
