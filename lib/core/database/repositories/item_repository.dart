import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../../utils/id_utils.dart';
import '../../utils/money.dart';
import '../../domain/member_role.dart';
import '../app_database.dart';
import '../costing/moving_average.dart';
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
    db.assertPermission(Permission.manageMasters);
    final id = _newId();
    final now = DateTime.now();
    await db.transaction(() async {
      await db
          .into(db.items)
          .insert(
            ItemsCompanion.insert(
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
            ),
          );
      await enqueue(
        firmId: firmId,
        entity: 'items',
        entityId: id,
        operation: 'insert',
      );
      if (stockType == 'tracked' && openingStock != 0) {
        await _recordMovement(
          StockMovementInput(
            itemId: id,
            kind: 'opening',
            quantity: openingStock,
            source: 'opening_balance',
            date: now,
            notes: 'Opening stock',
          ),
        );
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

  /// Live items, name-ordered, re-emitted on any write.
  ///
  /// [search] runs in SQL across name, SKU, HSN and barcode, so it is not
  /// capped: a caller that filters the in-memory result set of a capped query
  /// (the Items list used to) can neither show nor find anything past row 1000,
  /// while its search box still promises "name, SKU, HSN or barcode".
  ///
  /// Pass `limit: 0` for no cap at all, which is what the Items list does; the
  /// default stays 1000 for callers that only need a plausible page. A cap a
  /// caller cannot see is a data-loss bug, so removing one is the caller's
  /// decision rather than a change to this default.
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
      query.where(
        (t) =>
            t.name.lower().like(s) |
            t.sku.lower().like(s) |
            t.hsn.lower().like(s) |
            t.barcode.lower().like(s),
      );
    }
    if (categoryId != null) {
      query.where((t) => t.categoryId.equals(categoryId));
    }
    if (limit > 0) query.limit(limit);
    return query.get();
  }

  Stream<List<ItemEntity>> watchAll({String search = '', int limit = 1000}) {
    // Capped by default (was unbounded): a decade of catalogue entries on one
    // screen rebuilds the whole grid on every keystroke. `limit: 0` opts out —
    // see [all].
    final query = db.select(db.items)
      ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    if (limit > 0) query.limit(limit);
    if (search.trim().isNotEmpty) {
      final s = '%${search.trim().toLowerCase()}%';
      query.where(
        (t) =>
            t.name.lower().like(s) |
            t.sku.lower().like(s) |
            t.hsn.lower().like(s) |
            t.barcode.lower().like(s),
      );
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
    db.assertPermission(Permission.manageMasters);
    await db.transaction(() async {
      final current = await getById(item.id);
      if (current == null || current.isDeleted) {
        throw StateError('Item no longer exists.');
      }
      await db.update(db.items).replace(item.copyWith(
        firmId: firmId,
        currentStock: current.currentStock,
        openingStock: current.openingStock,
        updatedAt: DateTime.now(),
      ));
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
    db.assertPermission(Permission.manageMasters);
    await db.transaction(() async {
      await (db.update(
        db.items,
      )..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).write(
        ItemsCompanion(
          isDeleted: const Value(true),
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await enqueue(
        firmId: firmId,
        entity: 'items',
        entityId: id,
        operation: 'update',
      );
    });
  }

  /// Undo a soft delete from the recycle bin.
  Future<void> restore(String id) async {
    db.assertPermission(Permission.manageMasters);
    await db.transaction(() async {
      await (db.update(
        db.items,
      )..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).write(
        ItemsCompanion(
          isDeleted: const Value(false),
          deletedAt: const Value(null),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await enqueue(
        firmId: firmId,
        entity: 'items',
        entityId: id,
        operation: 'update',
      );
    });
  }

  /// Permanent delete — only reachable from the recycle bin. Refuses when
  /// stock history exists for the item.
  Future<void> deleteForever(String id) async {
    db.assertPermission(Permission.purge);
    await db.transaction(() async {
      final history = db.select(db.stockMovements)
        ..where((t) => t.firmId.equals(firmId) & t.itemId.equals(id))
        ..limit(1);
      if (await history.getSingleOrNull() != null) {
        throw StateError(
          'This item has stock history and cannot be removed permanently.',
        );
      }
      await (db.delete(
        db.items,
      )..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).go();
      await enqueue(
        firmId: firmId,
        entity: 'items',
        entityId: id,
        operation: 'delete',
      );
    });
  }

  // ---- Stock ledger ----

  Future<void> _recordMovement(StockMovementInput input) async {
    // The three writes below (insert the movement, enqueue it, rewrite
    // currentStock) MUST be atomic together: `currentStock` is a cached
    // balance derived from the movement log, so an error or an app kill between
    // the insert and the update leaves the two permanently disagreeing and the
    // stock ledger — the table of record — contradicting every count. Nothing
    // in here opens a transaction of its own, so callers that are not already
    // inside one (the stock-adjustment screen) must wrap this call; see
    // [applyStockEffect].
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
    // What this movement is worth, decided once and written down.
    //
    // An inbound movement takes the cost its caller supplied (a bill line's
    // net unit cost). An outbound one takes the running average, computed by
    // replaying this item's log up to but not including this row — which is
    // what makes the average independent of the order documents happen to be
    // saved in, rather than an artefact of it.
    final Decimal unitCost = input.quantity > 0
        ? (input.unitCost ?? Money.of(item.purchasePrice))
        : await _averageBefore(input.itemId, input.date) ??
              Money.of(item.purchasePrice);
    await db
        .into(db.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            // Monotonic counter: several lines of one invoice post in the same
            // microsecond, and the timestamp-only id collided on the PK.
            id: movementId,
            firmId: firmId,
            itemId: input.itemId,
            kind: input.kind,
            quantity: input.quantity,
            balanceAfter: Value(newBalance),
            unitCost: Value(unitCost.toDouble()),
            source: input.source,
            sourceId: Value(input.sourceId),
            sourceLineId: Value(input.sourceLineId),
            godownId: Value(input.godownId),
            sourceNumber: Value(input.sourceNumber),
            date: input.date,
            notes: Value(input.notes),
          ),
        );
    // Movements are the stock ledger of record; a restore must carry them.
    await enqueue(
      firmId: firmId,
      entity: 'stock_movements',
      entityId: movementId,
      operation: 'insert',
    );
    await db
        .update(db.items)
        .replace(
          item.copyWith(currentStock: newBalance, updatedAt: DateTime.now()),
        );
  }

  /// The moving average cost of [itemId] at [moment], or null when it is
  /// undefined (an item that has never been bought).
  ///
  /// Reads the item's whole movement log and replays it, excluding the movement
  /// about to be written. That is expensive per movement and deliberately so:
  /// a cached running average would be one stale row away from being wrong
  /// after a document is edited, a quotation is converted or a bill is
  /// soft-deleted, and the wrong figure here is a wrong margin in every
  /// report built on it.
  ///
  /// Ordering is `date, id` — the id is a monotonic counter, so two movements
  /// written in the same microsecond still have a defined order, and the
  /// average depends on which came first.
  Future<Decimal?> _averageBefore(String itemId, DateTime moment) async {
    final rows =
        await (db.select(db.stockMovements)
              ..where((t) => t.firmId.equals(firmId) & t.itemId.equals(itemId))
              ..orderBy([
                (t) => OrderingTerm.asc(t.date),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();

    // Everything dated at or before `moment` is history; anything later has
    // not happened yet. A row sharing the exact timestamp is counted, because
    // the new movement is appended after it and so sits behind it in the log.
    final history = rows.where((row) => !row.date.isAfter(moment)).toList();

    var costing = MovingAverageCosting.initial();
    for (final row in history) {
      final (next, _) = costing.apply(
        CostedMovement(
          id: row.id,
          kind: row.kind,
          quantity: row.quantity,
          unitCost: Money.of(row.unitCost),
        ),
      );
      costing = next;
    }
    return costing.average;
  }

  /// One-shot backfill: gives every existing movement the cost it should have
  /// carried, and returns how many rows were rewritten.
  ///
  /// Movements written before costing existed carry `unit_cost = 0`, so every
  /// item-profit report built on them would report the whole cost of sales as
  /// zero and read as if the shop sold everything at pure profit. Rather than
  /// ask the shop to re-enter last year's bills, the log is replayed and
  /// stamped from the documents that produced it.
  ///
  /// The join back to the bill line is what makes this *provably* right rather
  /// than approximately right:
  ///
  ///  * `source_line_id` names the exact line when the row was written by a
  ///    current build. That is the whole reason the column exists — a bill may
  ///    legitimately carry the same item twice at different rates, and matching
  ///    by item alone would pick the wrong one half the time.
  ///  * Rows written before the column existed fall back to `source_id` →
  ///    `purchase_bill_items` filtered on the same item. If the bill has exactly
  ///    one such line the answer is certain. If it has several, the movements
  ///    are consumed in log order against the lines in `sort_order`, which
  ///    reproduces the order the lines were saved in.
  ///
  /// Idempotent: re-running recomputes from the same inputs and writes the
  /// same figures, so it is safe to call again after fixing a costing bug.
  ///
  /// Ordered by `date, id` — the same order the live writer replays in.
  Future<int> backfillUnitCosts() async {
    // Ordered exactly as `_averageBefore` orders it, because the two have to
    // agree: if the backfill replayed in a different order than the live
    // writer does, the costs it stamps would drift from the ones the next
    // movement computes.
    final movements =
        await (db.select(db.stockMovements)
              ..where((t) => t.firmId.equals(firmId))
              ..orderBy([
                (t) => OrderingTerm.asc(t.date),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    if (movements.isEmpty) return 0;

    // Bill lines, keyed by id and by (bill, item), loaded once rather than per
    // movement: a firm with years of purchases would otherwise issue one
    // query per movement.
    final billLines = <String, PurchaseBillItemEntity>{};
    final nonCreditBills = <String>{};
    final byBillAndItem = <String, List<PurchaseBillItemEntity>>{};
    final sourceIds = movements
        .map((m) => m.sourceId)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    if (sourceIds.isNotEmpty) {
      final bills = await (db.select(db.purchaseBills)..where((t) =>
          t.firmId.equals(firmId) & t.id.isIn(sourceIds))).get();
      nonCreditBills.addAll(bills.where((b) => !b.itcEligible).map((b) => b.id));
      final lines = await (db.select(
        db.purchaseBillItems,
      )..where((t) => t.billId.isIn(sourceIds))).get();
      for (final line in lines) {
        billLines[line.id] = line;
        final itemId = line.itemId;
        if (itemId == null) continue;
        byBillAndItem.putIfAbsent('${line.billId}|$itemId', () => []).add(line);
      }
      for (final list in byBillAndItem.values) {
        list.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      }
    }

    // How many lines of each (bill, item) have been handed out already, so a
    // duplicated item walks its lines in order instead of reusing the first.
    final consumed = <String, int>{};

    Decimal? costFor(StockMovementEntity movement) {
      if (movement.quantity <= 0) return null;

      final lineId = movement.sourceLineId;
      if (lineId != null) {
        final line = billLines[lineId];
        if (line != null) {
          return _netUnitCost(nonCreditBills.contains(line.billId) ? line.total : line.taxableValue, line.quantity);
        }
      }

      final sourceId = movement.sourceId;
      if (sourceId == null) return null;
      final lines = byBillAndItem['$sourceId|${movement.itemId}'];
      if (lines == null || lines.isEmpty) return null;
      final key = '$sourceId|${movement.itemId}';
      final index = consumed[key] ?? 0;
      if (index >= lines.length) return null;
      consumed[key] = index + 1;
      final line = lines[index];
      return _netUnitCost(nonCreditBills.contains(line.billId) ? line.total : line.taxableValue, line.quantity);
    }

    // Group by item: each item's average is its own running total, and
    // interleaving two items' rows in one accumulator would average them
    // together.
    final byItem = <String, List<StockMovementEntity>>{};
    for (final movement in movements) {
      byItem.putIfAbsent(movement.itemId, () => []).add(movement);
    }

    var rewritten = 0;
    await db.transaction(() async {
      for (final rows in byItem.values) {
        final costs = replay([
          for (final row in rows)
            CostedMovement(
              id: row.id,
              kind: row.kind,
              quantity: row.quantity,
              unitCost: costFor(row) ?? Money.of(row.unitCost),
            ),
        ]);
        for (final row in rows) {
          final cost = costs[row.id] ?? Decimal.zero;
          if (cost == Money.of(row.unitCost)) continue;
          await (db.update(db.stockMovements)
                ..where((t) => t.id.equals(row.id)))
              .write(StockMovementsCompanion(unitCost: Value(cost.toDouble())));
          rewritten++;
        }
      }
    });
    return rewritten;
  }

  /// A bill line's cost per unit, excluding recoverable tax.
  ///
  /// `taxableValue` and not `total`: the difference is the GST credit, which
  /// is not part of the cost of the goods and must not be capitalised into
  /// stock. A line with no quantity cannot be divided by, and has no cost to
  /// record.
  static Decimal? _netUnitCost(double taxableValue, double quantity) {
    if (quantity == 0) return null;
    return (Money.of(taxableValue) / Money.of(quantity)).toDecimal(
      scaleOnInfinitePrecision: 4,
    );
  }

  /// Applies a stock effect for a document.
  ///
  /// Call within a transaction. This deliberately does NOT open one — the
  /// document repositories already hold one, and nesting would need drift's
  /// `TransactionExecutor` — but the movement insert and the `currentStock`
  /// update inside are two separate writes, so a caller outside a transaction
  /// (the stock-adjustment screen) must supply one itself.
  Future<void> applyStockEffect({
    required String itemId,
    required double quantity, // signed: negative for sales
    required String kind,
    required String source,
    String? sourceId,
    String? sourceLineId,
    String? sourceNumber,
    DateTime? date,
    String? notes,
    String? godownId,
    Decimal? unitCost,
  }) async {
    if (kind == 'adjustment' || source == 'manual') {
      db.assertPermission(Permission.manageMasters);
    }
    await _recordMovement(
      StockMovementInput(
        itemId: itemId,
        kind: kind,
        quantity: quantity,
        source: source,
        sourceId: sourceId,
        sourceLineId: sourceLineId,
        sourceNumber: sourceNumber,
        date: date ?? DateTime.now(),
        notes: notes,
        godownId: godownId,
        unitCost: unitCost,
      ),
    );
  }

  Stream<List<StockMovementEntity>> watchMovements(
    String itemId, {
    int limit = 200,
  }) {
    final query = db.select(db.stockMovements)
      ..where((t) => t.firmId.equals(firmId) & t.itemId.equals(itemId))
      ..orderBy([(t) => OrderingTerm.desc(t.date)])
      ..limit(limit);
    return query.watch();
  }

  /// Every movement in the firm, watched.
  ///
  /// Not for display — this is a change signal. `currentStock` is a cached
  /// balance that every movement rewrites, so a screen that wants fresh totals
  /// watches this and re-reads rather than polling or waiting for a tab
  /// rebuild that the nav shell's IndexedStack never sends.
  Stream<List<StockMovementEntity>> watchAllMovements({int limit = 1}) {
    final query = db.select(db.stockMovements)
      ..where((t) => t.firmId.equals(firmId))
      ..orderBy([(t) => OrderingTerm.desc(t.date)])
      ..limit(limit);
    return query.watch();
  }

  Future<List<StockMovementEntity>> movements(
    String itemId, {
    int limit = 500,
  }) async {
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
      // A service carries no physical stock, so a service left 'tracked' would
      // sit here holding a frozen opening balance forever — the same test the
      // movement writer uses to decide it isn't counted.
      if (i.isService || i.stockType != 'tracked') continue;
      total += i.currentStock * (atSale ? i.salePrice : i.purchasePrice);
    }
    return total;
  }

  Future<List<ItemEntity>> lowStock() async {
    final query = db.select(db.items)
      ..where(
        (t) =>
            t.firmId.equals(firmId) &
            t.isDeleted.equals(false) &
            t.isService.equals(false) &
            t.stockType.equals('tracked') &
            t.lowStockAlert.isBiggerThanValue(0) &
            t.currentStock.isSmallerOrEqual(t.lowStockAlert),
      )
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }

  // ---- Categories & units ----

  Future<CategoryEntity> createCategory(
    String name, {
    String kind = 'item',
  }) async {
    final id = 'cat_${IdUtils.newId()}';
    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: id,
            firmId: firmId,
            name: name,
            kind: Value(kind),
          ),
        );
    await enqueue(
      firmId: firmId,
      entity: 'categories',
      entityId: id,
      operation: 'insert',
    );
    return (db.select(
      db.categories,
    )..where((t) => t.id.equals(id))).getSingle();
  }

  Future<List<CategoryEntity>> categories({String kind = 'item'}) async {
    final query = db.select(db.categories)
      ..where((t) => t.firmId.equals(firmId) & t.kind.equals(kind))
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }

  Future<void> deleteCategory(String id) async {
    db.assertPermission(Permission.manageMasters);
    await (db.delete(
      db.categories,
    )..where((t) => t.id.equals(id) & t.firmId.equals(firmId))).go();
    await enqueue(
      firmId: firmId,
      entity: 'categories',
      entityId: id,
      operation: 'delete',
    );
  }

  Future<UnitEntity> createUnit(String name, String symbol) async {
    final id = 'unt_${IdUtils.newId()}';
    await db
        .into(db.units)
        .insert(
          UnitsCompanion.insert(
            id: id,
            firmId: firmId,
            name: name,
            symbol: symbol,
            isStandard: const Value(false),
          ),
        );
    await enqueue(
      firmId: firmId,
      entity: 'units',
      entityId: id,
      operation: 'insert',
    );
    return (db.select(db.units)..where((t) => t.id.equals(id))).getSingle();
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

  /// Which line of the source document this movement came from.
  final String? sourceLineId;

  final String? godownId;

  /// What this movement cost per unit.
  ///
  /// Supplied by the caller **only for inbound movements**, where the cost is
  /// known exactly: the bill line's net unit cost, excluding recoverable GST.
  /// For an outbound movement the caller has no cost to give — the whole point
  /// of a moving average is that the cost of goods leaving stock is whatever
  /// the running average says at that moment — so leaving it null is not an
  /// omission but the correct spelling.
  final Decimal? unitCost;

  const StockMovementInput({
    required this.itemId,
    required this.kind,
    required this.quantity,
    required this.source,
    this.sourceId,
    this.sourceNumber,
    required this.date,
    this.notes,
    this.sourceLineId,
    this.godownId,
    this.unitCost,
  });
}
