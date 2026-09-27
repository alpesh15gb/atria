import 'package:drift/drift.dart';

/// Customers and suppliers. A party can be both.
///
/// [openingBalanceType] records whether the opening balance is a debit ("dr",
/// customer owes us) or credit ("cr", we owe the supplier).
@DataClassName('PartyEntity')
@TableIndex(name: 'idx_parties_firm_name', columns: {#firmId, #name})
class Parties extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint('NOT NULL REFERENCES firms(id) ON DELETE CASCADE')();
  TextColumn get name => text().withLength(min: 1, max: 160)();
  TextColumn get type => text()(); // customer | supplier | both
  TextColumn get gstin => text().nullable()();
  TextColumn get pan => text().nullable()();
  /// registered | unregistered | consumer | composition | overseas | sez | special
  TextColumn get gstType => text().withDefault(const Constant('unregistered'))();
  TextColumn get contactPerson => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get addressLine1 => text().nullable()();
  TextColumn get addressLine2 => text().nullable()();
  TextColumn get city => text().nullable()();
  TextColumn get stateCode => text().nullable()();
  TextColumn get pincode => text().nullable()();
  RealColumn get openingBalance => real().withDefault(const Constant(0))();
  TextColumn get openingBalanceType => text().withDefault(const Constant('dr'))();
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

/// Item/service categories.
@DataClassName('CategoryEntity')
class Categories extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint('NOT NULL REFERENCES firms(id) ON DELETE CASCADE')();
  TextColumn get name => text().withLength(min: 1, max: 80)();
  /// item | expense
  TextColumn get kind => text().withDefault(const Constant('item'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Measurement units (user-defined on top of the built-in standard set).
@DataClassName('UnitEntity')
class Units extends Table {
  TextColumn get id => text()();
  TextColumn get firmId => text().customConstraint('NOT NULL REFERENCES firms(id) ON DELETE CASCADE')();
  TextColumn get name => text().withLength(min: 1, max: 40)();
  TextColumn get symbol => text().withLength(min: 1, max: 12)();
  BoolColumn get isStandard => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
