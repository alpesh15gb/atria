import 'package:drift/drift.dart';

import '../../utils/id_utils.dart';
import '../app_database.dart';
import 'stock_movement_ids.dart';
import 'sync_mixin.dart';

/// Inventory: items, stock tracking and the stock ledger.
class ItemRepository with SyncQueueMixin {
  ItemRepository(this.db, this.firmId);

  @override
  final AppDatabase db;

  final String firmId;

  Future<ItemEntity> create({
    required String name,
    String? sku,
    String? hsn,
    String? categoryId,
    String unit = 'pcs',
    double salePrice = 0,
    double purchasePrice = 0,
    double? wholesalePrice,
    double? mrp,
    double gstRate = 0,
    double cessRate = 0,
    String taxMode = 'exclusive',
    bool isService = false,
    String stockType = 'tracked',
    double openingStock = 0,
    double lowStockAlert = 0,
    String? barcode,
    String? description,
  }) async {
    final id = _newId();
    final now = DateTime.now();
    await db.transaction(() async {
      await db.into(db.items).insert(ItemsCompanion.insert(
            id: id,
            firmId: firmId,
            name: name,
            sku: Value(sku),
            hsn: Value(hsn),
            categoryId: Value(categoryId),
            unit: Value(unit),
            salePrice: Value(salePrice),
            purchasePrice: Value(purchasePrice),
            wholesalePrice: Value(wholesalePrice),
            mrp: Value(mrp),
            gstRate: Value(gstRate),
            cessRate: Value(cessRate),
            taxMode: Value(taxMode),
            isService: Value(isService),
            stockType: Value(stockType),
            openingStock: Value(openingStock),
            // The opening balance is posted as a stock movement below, which
            // sets currentStock from it. Seeding the column here too would
            // double-count it (movement reads currentStock + openingStock).
            currentStock: const Value(0),
            lowStockAlert: Value(lowStockAlert),
            barcode: Value(barcode),
            description: Value(description),
            createdAt: Value(now),
            updatedAt: Value(now),
          ));
      await enqueue(
          firmId: firmId, entity: 'items', entityId: id, operation: 'insert');
      if (stockType == 'tracked' && openingStock != 0) {
        await _recordMovement(StockMovementInput(
          itemId: id,
          kind: 'opening',
          quantity: openingStock,
          source: 'opening_balance',
          date: now,
          notes: 'Opening stock',
        ));
      }
    });
    return (await getById(id))!;
  }

  Future<ItemEntity?> getById(String id) async {
    final query = db.select(db.items)
      ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
    return query.getSingleOrNull();
  }

  Stream<ItemEntity?> watchById(String id) {
    final query = db.select(db.items)
      ..where((t) => t.id.equals(id) & t.firmId.equals(firmId));
    return query.watchSingleOrNull();
  }

  Future<List<ItemEntity>> all({
    String search = '',
    String? categoryId,
    int limit = 1000,
  }) async {
    final query = db.select(db.items)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    if (search.trim().isNotEmpty) {
      final s = '%${search.trim().toLowerCase()}%';
      query.where((t) =>
          t.name.lower().like(s) |
          t.sku.lower().like(s) |
          t.hsn.lower().like(s) |
          t.barcode.lower().like(s));
    }
    if (categoryId != null) {
      query.where((t) => t.categoryId.equals(categoryId));
    }
    query.limit(limit);
    return query.get();
  }

  Stream<List<ItemEntity>> watchAll({String search = '', int limit = 1000}) {
    // Capped (was unbounded): a decade of catalogue entries on one screen
    // rebuilds the whole grid on every keystroke. The search narrows long
    // lists well before 1000.
    final query = db.select(db.items)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    if (limit > 0) query.limit(limit);
    if (search.trim().isNotEmpty) {
      final s = '%${search.trim().toLowerCase()}%';
      query.where((t) =>
          t.name.lower().like(s) | t.sku.lower().like(s) | t.hsn.lower().like(s));
    }
    return query.watch();
  }

  /// Rows sitting in the recycle bin, newest deletion first.
  Stream<List<ItemEntity>> watchDeleted() {
    final query = db.select(db.items)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(true))
      ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]);
    return query.watch();
  }

  Future<ItemEntity> update(ItemEntity item) async {
    await db.transaction(() async {
      await db.update(db.items)
          .replace(item.copyWith(updatedAt: DateTime.now()));
      await enqueue(
        firmId: firmId,
        entity: 'items',
        entityId: item.id,
        operation: 'update',
      );
    });
    return (await getById(item.id))!;
  }

  /// Soft-deletes into the recycle bin. Ledger history (stock movements)
  /// keeps pointing at the row, which is exactly why items must never be
  /// hard-deleted while any history exists.
  Future<void> delete(String id) async {
    await db.transaction(() async {
      await (db.update(db.items)
            ..where((t) => t.id.equals(id) & t.firmId.equals(firmId)))
          .write(ItemsCompanion(
        isDeleted: const Value(true),
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ));
      await enqueue(
          firmId: firmId, entity: 'items', entityId: id, operation: 'update');
    });
  }

  /// Undo a soft delete from the recycle bin.
  Future<void> restore(String id) async {
    await db.transaction(() async {
      await (db.update(db.items)
            ..where((t) => t.id.equals(id) & t.firmId.equals(firmId)))
          .write(ItemsCompanion(
        isDeleted: const Value(false),
        deletedAt: const Value(null),
        updatedAt: Value(DateTime.now()),
      ));
      await enqueue(
          firmId: firmId, entity: 'items', entityId: id, operation: 'update');
    });
  }

  /// Permanent delete — only reachable from the recycle bin. Refuses when
  /// stock history exists for the item.
  Future<void> deleteForever(String id) async {
    await db.transaction(() async {
      final history = db.select(db.stockMovements)
        ..where((t) => t.firmId.equals(firmId) & t.itemId.equals(id))
        ..limit(1);
      if (await history.getSingleOrNull() != null) {
        throw StateError(
            'This item has stock history and cannot be removed permanently.');
      }
      await (db.delete(db.items)
          ..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).go();
      await enqueue(
          firmId: firmId, entity: 'items', entityId: id, operation: 'delete');
    });
  }

  // ---- Stock ledger ----

  Future<void> _recordMovement(StockMovementInput input) async {
    final item = await getById(input.itemId);
    if (item == null) {
      // A missing item row must never pass silently: the stock ledger would
      // disagree with the documents forever after.
      throw StateError('Stock movement for unknown item ${input.itemId}.');
    }
    if (item.isService || item.stockType != 'tracked') {
      // Services and untracked goods have no stock to move; posting a
      // movement would corrupt their (unused) cached balance.
      return;
    }
    // Negative stock is allowed at the ledger layer (see the matching note
    // in sales_repository): billing can precede the purchase entry.
    final newBalance = item.currentStock + input.quantity;
    final movementId = newStockMovementId();
    await db.into(db.stockMovements).insert(StockMovementsCompanion.insert(
          // Monotonic counter: several lines of one invoice post in the same
          // microsecond, and the timestamp-only id collided on the PK.
          id: movementId,
          firmId: firmId,
          itemId: input.itemId,
          kind: input.kind,
          quantity: input.quantity,
          balanceAfter: Value(newBalance),
          source: input.source,
          sourceId: Value(input.sourceId),
          sourceNumber: Value(input.sourceNumber),
          date: input.date,
          notes: Value(input.notes),
        ));
    // Movements are the stock ledger of record; a restore must carry them.
    await enqueue(
      firmId: firmId,
      entity: 'stock_movements',
      entityId: movementId,
      operation: 'insert',
    );
    await db.update(db.items).replace(
          item.copyWith(currentStock: newBalance, updatedAt: DateTime.now()),
        );
  }

  /// Applies a stock effect for a document. Call within a transaction.
  Future<void> applyStockEffect({
    required String itemId,
    required double quantity, // signed: negative for sales
    required String kind,
    required String source,
    String? sourceId,
    String? sourceNumber,
    DateTime? date,
    String? notes,
  }) async {
    await _recordMovement(StockMovementInput(
      itemId: itemId,
      kind: kind,
      quantity: quantity,
      source: source,
      sourceId: sourceId,
      sourceNumber: sourceNumber,
      date: date ?? DateTime.now(),
      notes: notes,
    ));
  }

  Stream<List<StockMovementEntity>> watchMovements(String itemId,
      {int limit = 200}) {
    final query = db.select(db.stockMovements)
      ..where((t) => t.firmId.equals(firmId) & t.itemId.equals(itemId))
      ..orderBy([(t) => OrderingTerm.desc(t.date)])
      ..limit(limit);
    return query.watch();
  }

  Future<List<StockMovementEntity>> movements(String itemId,
      {int limit = 500}) async {
    final query = db.select(db.stockMovements)
      ..where((t) => t.firmId.equals(firmId) & t.itemId.equals(itemId))
      ..orderBy([(t) => OrderingTerm.desc(t.date)])
      ..limit(limit);
    return query.get();
  }

  /// Total stock value at cost/sale price.
  Future<double> stockValue({bool atSale = true}) async {
    final items = await all();
    double total = 0;
    for (final i in items) {
      if (i.stockType != 'tracked') continue;
      total += i.currentStock * (atSale ? i.salePrice : i.purchasePrice);
    }
    return total;
  }

  Future<List<ItemEntity>> lowStock() async {
    final query = db.select(db.items)
      ..where((t) =>
          t.firmId.equals(firmId) &
          t.isDeleted.equals(false) &
          t.stockType.equals('tracked') &
          t.lowStockAlert.isBiggerThanValue(0) &
          t.currentStock.isSmallerOrEqual(t.lowStockAlert))
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }

  // ---- Categories & units ----

  Future<CategoryEntity> createCategory(String name, {String kind = 'item'}) async {
    final id = 'cat_${IdUtils.newId()}';
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          id: id,
          firmId: firmId,
          name: name,
          kind: Value(kind),
        ));
    await enqueue(
        firmId: firmId, entity: 'categories', entityId: id, operation: 'insert');
    return (db.select(db.categories)
          ..where((t) => t.id.equals(id)))
        .getSingle();
  }

  Future<List<CategoryEntity>> categories({String kind = 'item'}) async {
    final query = db.select(db.categories)
      ..where((t) => t.firmId.equals(firmId) & t.kind.equals(kind))
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }

  Future<void> deleteCategory(String id) async {
    await (db.delete(db.categories)
        ..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).go();
    await enqueue(
        firmId: firmId, entity: 'categories', entityId: id, operation: 'delete');
  }

  Future<UnitEntity> createUnit(String name, String symbol) async {
    final id = 'unt_${IdUtils.newId()}';
    await db.into(db.units).insert(UnitsCompanion.insert(
          id: id,
          firmId: firmId,
          name: name,
          symbol: symbol,
          isStandard: const Value(false),
        ));
    await enqueue(
        firmId: firmId, entity: 'units', entityId: id, operation: 'insert');
    return (db.select(db.units)
          ..where((t) => t.id.equals(id)))
        .getSingle();
  }

  Future<List<UnitEntity>> units() async {
    final query = db.select(db.units)
      ..where((t) => t.firmId.equals(firmId))
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }

  String _newId() => 'itm_${IdUtils.newId()}';
}

class StockMovementInput {
  final String itemId;
  final String kind;
  final double quantity;
  final String source;
  final String? sourceId;
  final String? sourceNumber;
  final DateTime date;
  final String? notes;

  const StockMovementInput({
    required this.itemId,
    required this.kind,
    required this.quantity,
    required this.source,
    this.sourceId,
    this.sourceNumber,
    required this.date,
    this.notes,
  });
}
