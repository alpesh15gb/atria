import 'package:drift/drift.dart';

/// Customers and suppliers. A party can be both.
///
/// [openingBalanceType] records whether the opening balance is a debit ("dr",
/// customer owes us) or credit ("cr", we owe the supplier).
@DataClassName('PartyEntity')
@TableIndex(name: 'idx_parties_firm_name', columns: {#firmId, #name})
class Parties extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();
  TextColumn get name => text().withLength(min: 1, max: 160)();
  TextColumn get type => text()(); // customer | supplier | both
  TextColumn get gstin => text().nullable()();

  /// The party group this party belongs to, for "Sale/Purchase By Party Group".
  ///
  /// A group is a `Categories` row with `kind == 'party'` — an application
  /// convention, not a schema one, because `Categories.kind` is free text.
  /// That is deliberate: a firm grouping its customers by city, by segment or
  /// by nothing in particular should not need a table per grouping scheme, and
  /// adding one later costs a column while adding a table costs a migration.
  ///
  /// Nullable, and null means ungrouped — which is what every existing party
  /// is, and must keep being until somebody groups it. Reports have to print
  /// an "Ungrouped" row for them rather than dropping them.
  TextColumn get categoryId => text().nullable()();
  TextColumn get pan => text().nullable()();

  /// registered | unregistered | consumer | composition | overseas | sez | special
  TextColumn get gstType =>
      text().withDefault(const Constant('unregistered'))();
  TextColumn get contactPerson => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get addressLine1 => text().nullable()();
  TextColumn get addressLine2 => text().nullable()();
  TextColumn get city => text().nullable()();
  TextColumn get stateCode => text().nullable()();
  TextColumn get pincode => text().nullable()();
  RealColumn get openingBalance => real().withDefault(const Constant(0))();
  TextColumn get openingBalanceType =>
      text().withDefault(const Constant('dr'))();
  RealColumn get creditLimit => real().nullable()();
  IntColumn get creditDays => integer().nullable()();
  TextColumn get notes => text().nullable()();

  /// Soft-delete flag for the recycle bin; hard delete only from there.
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Item, expense and party categories.
///
/// One table for all three because a firm organises the same way in each case,
/// and three tables for three `kind` values buys nothing — a category's only
/// difference is which screen offers it.
@DataClassName('CategoryEntity')
class Categories extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();
  TextColumn get name => text().withLength(min: 1, max: 80)();

  /// item | expense | party
  ///
  /// Free text by design — a firm grouping customers by city and one grouping
  /// by segment are the same operation on the same row.
  TextColumn get kind => text().withDefault(const Constant('item'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Measurement units (user-defined on top of the built-in standard set).
@DataClassName('UnitEntity')
class Units extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint(
    'NOT NULL REFERENCES firms(id) ON DELETE CASCADE',
  )();
  TextColumn get name => text().withLength(min: 1, max: 40)();
  TextColumn get symbol => text().withLength(min: 1, max: 12)();
  BoolColumn get isStandard => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
