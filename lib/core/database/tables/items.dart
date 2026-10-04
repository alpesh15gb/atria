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
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get sku => text().nullable()();
  TextColumn get hsn => text().nullable()(); // HSN for goods, SAC for services
  TextColumn get categoryId => text().nullable()();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  RealColumn get salePrice => real().withDefault(const Constant(0))();
  RealColumn get purchasePrice => real().withDefault(const Constant(0))();

  /// How this item's stock value is costed. `moving_average` today.
  ///
  /// Per master data rather than per firm, because the choice belongs to the
  /// goods: a trader reselling one item FIFO and another weighted-average has a
  /// real reason, and a shop owner cannot be asked to make the same decision
  /// for forty items. Only `moving_average` is implemented; the column exists
  /// so that adding a method later is a value, not a migration.
  TextColumn get costingMethod =>
      text().withDefault(const Constant('moving_average'))();

  /// The godown this item's stock normally sits in. Null means "no preference",
  /// which is the correct value for every item in a firm with one godown and
  /// also for a firm that has not created any yet.
  TextColumn get defaultGodownId => text().nullable()();
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

  /// What this movement was worth per unit, at the moment it happened.
  ///
  /// Stored on the movement rather than read back from `items.purchasePrice`
  /// because that column is a *current* catalogue field: valuing last quarter's
  /// movements at today's purchase price means last quarter's profit changes
  /// when somebody buys the item today, and a P&L that moves after the fact is
  /// worse than no P&L.
  ///
  /// Meaning by [kind]:
  ///  * `purchase` — the bill line's net unit cost, **excluding** recoverable
  ///    GST. Input tax credit is not part of what the goods cost the shop.
  ///  * `purchase_return` — the average at the moment, so a return reduces
  ///    value by what the goods actually left the business at worth.
  ///  * `sale` / `sale_return` — the moving average at the moment, which is
  ///    what the cost of those goods was.
  ///  * `opening` — the item's purchase price, which is an **estimate**: the
  ///    real opening cost is unknowable once the invoices are gone. Recorded as
  ///    such rather than presented as fact.
  ///  * `adjustment` — carried forward from the movement being adjusted.
  ///
  /// Zero is a real value here (an item given free) and so is a legacy row
  /// that predates this column; [MovingAverageCosting] tells the two apart by
  /// `kind`, not by zero.
  RealColumn get unitCost => real().withDefault(const Constant(0))();

  /// sales_invoices | purchase_bills | manual | opening_balance
  TextColumn get source => text()();
  TextColumn get sourceId => text().nullable()();

  /// Which line of the source document produced this movement.
  ///
  /// `sourceId` alone cannot order two movements from one bill that share an
  /// item — a bill with "Widget ×5" on two rows is legal and posts two rows
  /// with the same `sourceId`. That made the replay backfill ambiguous: it
  /// could join an inbound movement to either line and get a different unit
  /// cost each time. With this, the backfill is provably right rather than
  /// right by luck.
  TextColumn get sourceLineId => text().nullable()();

  /// Where the stock moved. Null = the firm's single, unnamed location, which
  /// is every movement written before this column existed.
  TextColumn get godownId => text().nullable()();

  TextColumn get sourceNumber => text().nullable()();
  DateTimeColumn get date => dateTime()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
