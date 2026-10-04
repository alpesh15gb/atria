import 'package:drift/drift.dart';

/// A place stock is held — a shop, a godown, a warehouse, a van.
///
/// Exists because "Stock Transfer Report" is otherwise a report about a
/// concept the database has no way to express: two movements of the same item
/// between two locations have identical item, quantity and kind, and nothing in
/// the ledger can say which went where.
///
/// A firm with one location never has to create a row. `stock_movements.godownId`
/// is null then, and every transfer report treats null as the single unnamed
/// location. Requiring a godown before the first purchase would make the
/// commonest case pay for the rare one.
@DataClassName('GodownEntity')
@TableIndex(name: 'idx_godowns_firm', columns: {#firmId})
class Godowns extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();
  TextColumn get name => text().withLength(min: 1, max: 100)();

  /// An address is optional because a godown is sometimes just "the back room"
  /// and a forced address field would get "Main Street" typed into it for the
  /// hundredth time.
  TextColumn get addressLine1 => text().nullable()();
  TextColumn get city => text().nullable()();
  TextColumn get stateCode => text().nullable()();

  /// Stock held here, cached. Like `items.currentStock` it is derived from the
  /// movement log, and the two can only disagree if a write is not atomic —
  /// which is why transfers must be written inside a transaction.
  RealColumn get currentStockQuantity =>
      real().withDefault(const Constant(0))();

  /// The one godown an item without a `defaultGodownId` posts to.
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();

  /// A godown can be archived rather than deleted once stock is in it:
  /// deleting one would orphan every movement that names it, and the transfer
  /// history is a tax record.
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
