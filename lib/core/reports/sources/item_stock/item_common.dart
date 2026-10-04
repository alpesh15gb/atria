import 'package:decimal/decimal.dart';
// `ReportRow` is named in [itemProfitNotes]'s signature.
import 'package:atria/core/reports/engine/report_result.dart';
// Not `show Value`: every predicate below is built from drift's expression
// operators (`|`, `&`, `not`) which live on extension types a narrowed import
// silently drops.
import 'package:drift/drift.dart' hide isNull;

import '../../../database/app_database.dart';
import '../../../utils/money.dart';
import '../../../database/costing/moving_average.dart';
import '../../engine/report_source.dart';
import '../../spec/report_spec.dart';
import '../../window/report_window.dart';
import '../transaction/transaction_common.dart' show signFor;

/// The cost per unit of each item's remaining stock, **as of now**.
///
/// **Not windowed, deliberately.** This values `items.currentStock` — what is
/// on the shelf today — so the average that goes with it has to be today's. The
/// window parameter would produce a valuation mixing today's quantity with a
/// cost from months ago, which is not an approximation of anything.
///
/// **A full log replay, and it has to be one.** The running average is a
/// function of every movement that came before, so an item whose only purchase
/// was two years ago has a well-defined average today and no trace of it inside
/// any recent window. Reading only the window's movements gives zero for every
/// item the firm has stopped buying — which is to say, for most of a healthy
/// catalogue — and a stock valuation of zero across the shop.
///
/// The replay is the same one `item_repository._averageBefore` performs when it
/// stamps a movement, using the same `MovingAverageCosting` and the same
/// `date, id` ordering, so a report and the ledger cannot disagree about what
/// something cost. **Ordered globally rather than per item**, so this is one
/// pass and not one query per item: a two-thousand-item catalogue would
/// otherwise be two thousand round trips on a phone.
///
/// Null when the item has never had a costed inbound movement — there is no
/// average to report, and the caller says so rather than inventing one.
Future<Map<String, Decimal>> averageCostByItem(
  AppDatabase db,
  String firmId, {
  String? selected,
}) async {
  final movements = db.stockMovements;
  // A typed `select` rather than `selectOnly`: `selectOnly` returns an
  // untyped `Selectable<dynamic>` whose `orderBy` callbacks infer as
  // `(dynamic)` and will not satisfy `OrderingTerm`. Every column needed is on
  // the movement itself, so there is nothing to aggregate and no reason to
  // reach for the aggregate API.
  final query = db.select(movements)
    ..where(
      (_) =>
          movements.firmId.equals(firmId) &
          itemScope(movements.itemId, selected),
    )
    // `id` last because the running average depends on order, and two movements
    // written in the same millisecond are only ordered by the monotonic id.
    ..orderBy([
      (m) => OrderingTerm.asc(m.itemId),
      (m) => OrderingTerm.asc(m.date),
      (m) => OrderingTerm.asc(m.id),
    ]);

  final costing = <String, MovingAverageCosting>{};
  final out = <String, Decimal>{};
  for (final row in await query.get()) {
    final itemId = row.itemId;
    final current = costing[itemId] ?? MovingAverageCosting.initial();
    // The stored `unitCost` is what the writer stamped at the time, and the
    // writer decided what that was. Passing it through unchanged means this
    // replay reproduces the ledger rather than re-deriving it.
    final (next, _) = current.apply(
      CostedMovement(
        id: row.id,
        kind: row.kind,
        quantity: row.quantity,
        unitCost: dec(row.unitCost),
      ),
    );
    costing[itemId] = next;
  }
  for (final entry in costing.entries) {
    final average = entry.value.average;
    if (average != null) out[entry.key] = average;
  }
  return out;
}

/// A margin as a percentage, or zero when there was no revenue.
///
/// Zero rather than blank or infinite: a percentage of zero is zero, and an
/// item that sold nothing has no margin rather than an unbounded one. Shared by
/// the item and category P&Ls so both compute the ratio identically — two
/// spellings of a margin is the kind of difference that shows up as a
/// one-column discrepancy between two reports of the same month.
///
/// A `percent` column is excluded from the total row by
/// `ReportColumn.isSummable` on its own, so "Total 340%" cannot be printed
/// without the spec being changed first.
Decimal marginPercent(Decimal profit, Decimal revenue) =>
    revenue == Decimal.zero
    ? Decimal.zero
    // **Three steps, and each one is load-bearing.** `(profit * 100) /
    // revenue` is exact in `Rational` — `Decimal /` returns a `Rational` and
    // the multiplication stays inside it, so nothing is lost here. Then
    // `.toDecimal(scaleOnInfinitePrecision: …)` is **mandatory**: a margin
    // of 1/3 has no finite decimal expansion and the bare `toDecimal()`
    // *throws* on one, so the ordinary case of a third of the revenue took
    // the whole report down instead of printing 33.33. And the scale is
    // deliberately **wider than the display** — `toDecimal` truncates, so
    // converting straight to 2 places gives 66.66 for two thirds where
    // `Money.round2` gives 66.67. Six places then one HALF_UP round is
    // what makes this agree with every other percentage in the app.
    : Money.round2(
        (profit * Decimal.fromInt(100) / revenue).toDecimal(
          scaleOnInfinitePrecision: 6,
        ),
      );

/// The columns the item-profit notes read, declared once.
///
/// A note that spells out `ReportColumn(key: 'sale', …)` gets no compiler help
/// when the column is renamed, and a typo there produces a silently-zero
/// figure in a sentence the reader is meant to trust. These are the keys
/// [itemProfitNotes] reads.
const ReportColumn itemNameColumn = ReportColumn(key: 'item', label: 'Item');
const ReportColumn itemSaleColumn = ReportColumn(
  key: 'sale',
  label: 'Sale value',
  kind: ReportValueKind.money,
);
const ReportColumn itemCostColumn = ReportColumn(
  key: 'cost',
  label: 'Cost',
  kind: ReportValueKind.money,
);

/// The cost warning, from whichever rows the caller built.
///
/// Sales with no cost at all. A margin of 100% is the most expensive wrong
/// number this folder can print, because it looks exactly like the firm's best
/// product rather than like missing data — so it is called out by name.
///
/// Takes the rows rather than a flag, so a report cannot compute an `uncosted`
/// list and then forget to pass it.
List<String> itemProfitNotes(List<ReportRow> rows) {
  final uncosted = <String>[];
  for (final row in rows) {
    final sale = row.number(itemSaleColumn);
    final cost = row.number(itemCostColumn);
    if (sale > Decimal.zero && cost == Decimal.zero) {
      uncosted.add(row.text(itemNameColumn));
    }
  }
  return uncostedNote(uncosted);
}

/// The item list, for a filter dropdown.
///
/// The same reasoning as `partyFilterOptions`, and the same consequence: this is
/// the **one** place the reports layer reads a firm's items. Two reports with
/// their own would sort or filter differently, and the reader would conclude
/// they cover different catalogues.
///
/// **Services are included.** An "item" in this app is a product *or* a service,
/// and a report filtered to goods alone silently omits every line the firm bills
/// as a service — which on a service business is all of them. Reports that are
/// genuinely about stock say so by filtering [ItemFilters.trackedOnly] instead,
/// where the exclusion is visible rather than baked into the picker.
///
/// Soft-deleted items are excluded: an item in the recycle bin is not one the
/// firm sells, and offering it means a P&L that opens on a deleted item.
Future<List<ReportFilterOption<Object?>>> itemFilterOptions(
  AppDatabase db,
  String firmId,
) async {
  final items =
      await (db.select(db.items)
            ..where((i) => i.firmId.equals(firmId) & i.isDeleted.equals(false))
            ..orderBy([(i) => OrderingTerm.asc(i.name)]))
          .get();
  return [
    for (final item in items)
      ReportFilterOption<Object?>(value: item.id, label: item.name),
  ];
}

/// The options callback every item-scoped report hands to its source.
///
/// **A named function, not an inline closure.** A `const` `ReportDefinition`
/// cannot contain a call, and `Future.value(…)` is a call — so an inline
/// `options:` callback makes the whole definition fail to compile as `const`,
/// which is what lets a spec be built in a test with no fixture.
Future<List<ReportFilterOption<Object?>>> itemOptions(
  AppDatabase db,
  String firmId,
  ReportSpec spec,
  String filterId,
) => filterId == kItemFilterId
    ? itemFilterOptions(db, firmId)
    : Future<List<ReportFilterOption<Object?>>>.value(const []);

/// The filter id every item-scoped report uses.
///
/// One id across the category, so the picker, the empty state and the export
/// header all read the same key — and so switching from Item Detail to Item Wise
/// P&L keeps the item, which is what a reader expects when looking at the same
/// product two ways.
const String kItemFilterId = 'itemId';

/// The item named by [filters], or null for "every item".
///
/// **Null is the useful answer, not a missing value.** Every report here has a
/// per-item form and an all-items form, and the all-items one is what a report
/// screen should open on — a reader who opens "Item Wise P&L" wants the list, and
/// one who wants a single product opens the same report and picks it. A source
/// that treated null as an error would have to invent a default item, and a
/// margin report for the wrong product is worse than the margin report for all
/// of them.
String? selectedItemId(Map<String, Object?> filters) {
  final value = filters[kItemFilterId];
  if (value == null) return null;
  final id = '$value'.trim();
  return id.isEmpty ? null : id;
}

/// Restricts an item-keyed expression to the selected item, when one is.
///
/// `Expression<String>` and not `Expression<String?>` because drift's `equals`
/// lives on the *non-null* extension type; a nullable column reads as
/// `Expression<String>` and compares fine.
Expression<bool> itemScope(Expression<String> itemId, String? selected) =>
    selected == null ? const Constant(true) : itemId.equals(selected);

/// Restricts a query to stock-keeping items.
///
/// **Applied by the stock reports, not by the picker.** A service has no stock
/// and no moving average, so including one in a stock valuation produces a row
/// whose quantity is zero and whose value is zero — which reads as "this item
/// exists and is worth nothing" rather than "this is not stock". The service is
/// still in the *sales* reports, because it is sold.
Expression<bool> stockKeeping($ItemsTable items) =>
    items.isService.equals(false) & items.stockType.equals('tracked');

/// The same test, for a row already fetched.
///
/// The reports hold `ItemEntity` from `allLiveItems` and only then decide
/// whether an item is stock — filtering in SQL would mean a second query and a
/// map, for a comparison of two already-loaded columns. Keeping the `stockType`
/// spelling in one place matters more than the duplication: it is a free-text
/// column, so `tracked` and `Track` would be different items to this code.
bool isStockKeeping(ItemEntity item) =>
    !item.isService && item.stockType == 'tracked';

/// What an item is, for the columns a report prints beside its figures.
///
/// Assembled once because five of the eleven reports need it and a report that
/// built its own would show the *item master's* current name against a movement
/// from last quarter — which is the same class of bug `party_report_by_item`
/// documents on the sales side, in the other direction.
class ItemInfo {
  const ItemInfo({
    required this.name,
    required this.sku,
    required this.hsn,
    required this.unit,
    required this.categoryId,
    required this.salePrice,
    required this.purchasePrice,
    required this.currentStock,
    required this.lowStockAlert,
    required this.isService,
  });

  /// The item's name **as it is now**. See [ItemFilters] and
  /// `party_report_by_item` for why a movement's item name comes from the line
  /// where one exists and this is only for master-data reports.
  final String name;
  final String sku;
  final String hsn;
  final String unit;
  final String? categoryId;
  final Decimal salePrice;
  final Decimal purchasePrice;
  final Decimal currentStock;
  final Decimal lowStockAlert;
  final bool isService;

  /// True when the item is tracked, has a stock position, and has been given a
  /// reorder level — the three conditions before "low stock" means anything.
  ///
  /// `lowStockAlert == 0` is **not** an alert of zero, it is the absence of one.
  /// Treating it as a level would put every item with no threshold configured on
  /// the report, and a Low Stock Summary listing the entire catalogue is a
  /// report nobody reads.
  bool get isLowStock =>
      !isService &&
      lowStockAlert > Decimal.zero &&
      currentStock <= lowStockAlert;
}

/// The view of an item that the reports print, as [Decimal].
///
/// **`currentStock` is the item's balance, not the window's.** It is the
/// `items` cache, which the movement writers keep current, and it is the only
/// figure that answers "what have I got on the shelf now". Summing the period's
/// movements instead would answer a different question and get it wrong twice:
/// the opening balance is stamped when the item was *created*, so on any item
/// created before the window it falls outside the window entirely and the sum
/// starts from nothing. Closing stock is therefore the master, and the window's
/// movements are the *flows* beside it.
ItemInfo infoFor(ItemEntity item) => ItemInfo(
  name: item.name,
  sku: item.sku ?? '',
  hsn: item.hsn ?? '',
  unit: item.unit,
  categoryId: item.categoryId,
  salePrice: Decimal.parse(item.salePrice.toString()),
  purchasePrice: Decimal.parse(item.purchasePrice.toString()),
  currentStock: Decimal.parse(item.currentStock.toString()),
  lowStockAlert: Decimal.parse(item.lowStockAlert.toString()),
  isService: item.isService,
);

/// The firm's items by id.
///
/// The query builder rather than `customSelect`, so a firm with two thousand
/// items gets drift's `IN (…)` variable chunking instead of a
/// `too many SQL variables` at 999.
Future<Map<String, ItemEntity>> itemsById(
  AppDatabase db,
  String firmId,
  List<String> ids,
) async {
  if (ids.isEmpty) return const {};
  final query = db.select(db.items)
    ..where((i) => i.firmId.equals(firmId) & i.id.isIn(ids));
  return {for (final item in await query.get()) item.id: item};
}

/// Every live item, keyed by id, for a report that opens on the master data.
///
/// Ordered by name so the report reads in the order the reader thinks in, and
/// **soft-deleted excluded**: an item in the recycle bin is not one the firm
/// sells.
Future<Map<String, ItemEntity>> allLiveItems(
  AppDatabase db,
  String firmId, {
  String? selected,
}) async {
  final query = db.select(db.items)
    ..where(
      (i) =>
          i.firmId.equals(firmId) &
          i.isDeleted.equals(false) &
          itemScope(i.id, selected),
    )
    ..orderBy([(i) => OrderingTerm.asc(i.name)]);
  return {for (final item in await query.get()) item.id: item};
}

/// The item-category name each item belongs to, or `Ungrouped`.
///
/// **Never null and never omitted.** `items.categoryId` is nullable and null
/// means nobody has classified this product yet — true of every item in every
/// firm that has not set up categories, which is every firm until the feature is
/// used. A report that dropped them would total short by exactly those items, and
/// the reader would have no way to know the products were missing rather than
/// quiet.
///
/// A **service** is filed under `Services` rather than `Ungrouped`, because "this
/// product has no category" and "this line is not a product" are different
/// statements and lumping them together makes a category report's ungrouped row
/// mean two things at once.
Future<Map<String, String>> itemCategoryNames(
  AppDatabase db,
  String firmId,
  Map<String, ItemEntity> items,
) async {
  const ungrouped = 'Ungrouped';
  const services = 'Services';
  final categoryIds = items.values
      .map((i) => i.categoryId)
      .whereType<String>()
      .toSet()
      .toList();
  final names = <String, String>{};
  if (categoryIds.isNotEmpty) {
    final query = db.select(db.categories)
      ..where((c) => c.firmId.equals(firmId) & c.id.isIn(categoryIds));
    for (final category in await query.get()) {
      names[category.id] = category.name;
    }
  }
  return {
    for (final entry in items.entries)
      entry.key: entry.value.isService
          ? services
          : entry.value.categoryId == null
          ? ungrouped
          : names[entry.value.categoryId] ?? ungrouped,
  };
}

/// What one item's stock did in the window, and what it is worth now.
///
/// **One pass over the movement log, not one query per report.** The eleven
/// reports in this folder ask the same four questions of the same table — what
/// came in, what went out, at what cost, and what is left — and a report that ran
/// its own would drift from its neighbour the day someone corrected one of them.
/// An Item Wise P&L and a Stock Summary that disagree about the same item is the
/// bug that costs a reader their afternoon, and it looks completely fine on
/// screen.
///
/// **Signs come from the movement, never recomputed.** A sale's movement is a
/// negative quantity and a purchase's is positive; deriving direction from
/// `docType` instead would mean a second sign rule that can disagree with the
/// one that wrote the movement in the first place.
///
/// **`unitCost` is the cost at the moment the goods moved** (schema v11), not
/// today's `items.purchasePrice`. Valuing last quarter's sales at today's
/// purchase price means last quarter's profit changes when somebody buys the
/// item this week, and a P&L that moves after the fact is worse than no P&L.
class ItemMovement {
  const ItemMovement({
    required this.inboundQty,
    required this.inboundValue,
    required this.outboundQty,
    required this.outboundValue,
    required this.saleQty,
    required this.saleValue,
    required this.saleReturnQty,
    required this.saleReturnValue,
    required this.purchaseReturnQty,
    required this.purchaseReturnValue,
  });

  /// Net quantity received, positive. Purchase returns reduce it.
  final Decimal inboundQty;
  final Decimal inboundValue;

  /// Net quantity issued, positive — the cost of what left, as a positive
  /// figure. Sale returns reduce it.
  final Decimal outboundQty;
  final Decimal outboundValue;

  /// Sales only, and returns only, kept apart because **Item Wise P&L needs
  /// revenue and its returns separately from cost and its returns**: they net
  /// against each other to produce a margin, and netting twice would hide a
  /// return entirely.
  final Decimal saleQty;
  final Decimal saleValue;
  final Decimal saleReturnQty;
  final Decimal saleReturnValue;
  final Decimal purchaseReturnQty;
  final Decimal purchaseReturnValue;

  /// **Not `const`.** `Decimal.zero` is a `static final`, and a default
  /// parameter or a const initializer needs a compile-time value. Making these
  /// `final` costs one object per process and saves a class of error that only
  /// shows up at compile time in a folder with eleven reports to write.
  static final ItemMovement zero = ItemMovement(
    inboundQty: Decimal.zero,
    inboundValue: Decimal.zero,
    outboundQty: Decimal.zero,
    outboundValue: Decimal.zero,
    saleQty: Decimal.zero,
    saleValue: Decimal.zero,
    saleReturnQty: Decimal.zero,
    saleReturnValue: Decimal.zero,
    purchaseReturnQty: Decimal.zero,
    purchaseReturnValue: Decimal.zero,
  );

  bool get isEmpty =>
      inboundQty == Decimal.zero &&
      outboundQty == Decimal.zero &&
      inboundValue == Decimal.zero &&
      outboundValue == Decimal.zero;
}

/// Σ movement per item, in one grouped pass.
///
/// **Grouped by item alone, with the sign applied in Dart from `kind`.** A
/// `SUM(CASE WHEN kind = 'sale' THEN … END)` would work and would put an
/// accounting rule inside a SQL string where no test can read it — the same
/// reasoning that forces the sign rule in `party_common.dart`.
///
/// **`opening` counts as inbound, but only on the day it was recorded.** It is a
/// real receipt of goods at an estimated cost — but the stamp is the wall clock
/// at item creation, so for an item created before the window it falls *outside*
/// it and never appears here.
///
/// That is why [infoFor] carries the balance rather than this map: a report that
/// summed movements to find closing stock would show an item created last year as
/// having nothing on the shelf. So this map answers **what moved in the window**,
/// `items.currentStock` answers **what is there now**, and neither substitutes
/// for the other.
Future<Map<String, ItemMovement>> movementsByItem(
  AppDatabase db,
  String firmId,
  ReportWindow window, {
  String? selected,
}) async {
  final qty = db.stockMovements.quantity.sum();
  final value = (db.stockMovements.quantity * db.stockMovements.unitCost).sum();
  final query = db.selectOnly(db.stockMovements)
    ..addColumns([db.stockMovements.itemId, db.stockMovements.kind, qty, value])
    ..where(
      db.stockMovements.firmId.equals(firmId) &
          ReportFilters.within(db.stockMovements.date, window) &
          itemScope(db.stockMovements.itemId, selected),
    )
    ..groupBy([db.stockMovements.itemId, db.stockMovements.kind]);

  final out = <String, ItemMovement>{};
  for (final row in await query.get()) {
    final itemId = row.read(db.stockMovements.itemId);
    if (itemId == null) continue;
    final kind = '${row.read(db.stockMovements.kind)}';
    // **The writer already signs the quantity, and not the way a reader
    // guesses.** `sales_repository.dart:458` writes `sale` as `-qty` and
    // `sale_return` as `+qty`; `purchase_repository.dart:310` writes `purchase`
    // as `+qty` and `purchase_return` as `-qty`. So the stored sign says which
    // way the shelf moved, and *this* code's job is only to say which bucket —
    // taking an absolute value here rather than inferring it keeps the two
    // halves from being confused: inferring gave a credit note's return as
    // another outbound, which left a returned bag on the shelf and its sale
    // quantity unsold.
    final q = dec(row.read(qty) ?? 0).abs();
    final v = dec(row.read(value) ?? 0).abs();
    final m = out[itemId] ?? ItemMovement.zero;

    switch (kind) {
      case 'purchase':
      case 'opening':
        out[itemId] = _merge(m, inQ: q, inV: v);
      case 'adjustment':
        // The one kind where the stored sign *is* the direction: a positive
        // adjustment is stock found and a negative one is stock written off,
        // and a valuation that ignored either would state a balance the shop
        // does not have.
        final signed = dec(row.read(qty) ?? 0);
        final signedValue = dec(row.read(value) ?? 0);
        out[itemId] = _merge(
          m,
          inQ: signed > Decimal.zero ? signed : Decimal.zero,
          outQ: -signed > Decimal.zero ? -signed : Decimal.zero,
          inV: signedValue > Decimal.zero ? signedValue : Decimal.zero,
          outV: -signedValue > Decimal.zero ? -signedValue : Decimal.zero,
        );
      case 'sale':
        out[itemId] = _merge(m, outQ: q, outV: v, saleQ: q, saleV: v);
      case 'sale_return':
        // Returns stock **in**, so it is inbound for the balance and still
        // counted as a return in its own column.
        out[itemId] = _merge(m, inQ: q, inV: v, saleReturnQ: q, saleReturnV: v);
      case 'purchase_return':
        // A return to the supplier takes stock back **out**.
        out[itemId] = _merge(
          m,
          outQ: q,
          outV: v,
          purchaseReturnQ: q,
          purchaseReturnV: v,
        );
    }
  }
  return out;
}

/// Adds movement onto an accumulator without ever re-stating all ten fields.
///
/// Written as **nullable** named-optionals rather than defaulting to
/// `Decimal.zero`, because that is a `static final` and a default parameter has
/// to be a compile-time constant. Null means "this movement did not touch this
/// field", which is also what a caller writes.
///
/// The two in/out pairs and the two return columns are **independent** — a
/// caller passes the balance side and the reason side together, and neither is
/// derived here. An earlier version folded the returns into the balance side
/// itself, which meant the switch above had to pass the balance twice on some
/// paths and never on others; two ways to get a balance right is one too many.
ItemMovement _merge(
  ItemMovement m, {
  Decimal? inQ,
  Decimal? inV,
  Decimal? outQ,
  Decimal? outV,
  Decimal? saleQ,
  Decimal? saleV,
  Decimal? saleReturnQ,
  Decimal? saleReturnV,
  Decimal? purchaseReturnQ,
  Decimal? purchaseReturnV,
}) => ItemMovement(
  inboundQty: m.inboundQty + (inQ ?? Decimal.zero),
  inboundValue: m.inboundValue + (inV ?? Decimal.zero),
  outboundQty: m.outboundQty + (outQ ?? Decimal.zero),
  outboundValue: m.outboundValue + (outV ?? Decimal.zero),
  saleQty: m.saleQty + (saleQ ?? Decimal.zero),
  saleValue: m.saleValue + (saleV ?? Decimal.zero),
  saleReturnQty: m.saleReturnQty + (saleReturnQ ?? Decimal.zero),
  saleReturnValue: m.saleReturnValue + (saleReturnV ?? Decimal.zero),
  purchaseReturnQty: m.purchaseReturnQty + (purchaseReturnQ ?? Decimal.zero),
  purchaseReturnValue:
      m.purchaseReturnValue + (purchaseReturnV ?? Decimal.zero),
);

/// The sales-side and purchase-side figures per item, from the invoice and bill
/// lines.
///
/// **Separate from [movementsByItem] on purpose.** Stock says what left the
/// shelf; a sales line says what was *sold*. They agree on a tracked item and
/// diverge on an untracked one, where no movement is written at all — so a
/// revenue report read off the movement log shows zero sales for every service
/// the firm bills, and a service business is entirely services.
///
/// Value is **taxable value, never `grandTotal`**: output tax is not revenue,
/// and a margin computed on the invoice total is a fraction of the tax.
class ItemTrading {
  const ItemTrading({
    required this.saleQty,
    required this.saleValue,
    required this.saleTax,
    required this.purchaseQty,
    required this.purchaseValue,
    required this.purchaseTax,
  });

  final Decimal saleQty;
  final Decimal saleValue;
  final Decimal saleTax;
  final Decimal purchaseQty;
  final Decimal purchaseValue;
  final Decimal purchaseTax;

  /// **Not `const`** — see [ItemMovement.zero].
  static final ItemTrading zero = ItemTrading(
    saleQty: Decimal.zero,
    saleValue: Decimal.zero,
    saleTax: Decimal.zero,
    purchaseQty: Decimal.zero,
    purchaseValue: Decimal.zero,
    purchaseTax: Decimal.zero,
  );

  bool get isEmpty =>
      saleValue == Decimal.zero && purchaseValue == Decimal.zero;
}

/// Σ signed sales and purchase lines per item.
///
/// **Grouped by `docType` as well as item, and signed in Dart** — the identical
/// shape and the identical reason as `party_common.dart`: a credit note stores
/// its line values **positive**, so an unsigned `SUM` over an invoice and its
/// return reports the value of both.
Future<Map<String, ItemTrading>> tradingByItem(
  AppDatabase db,
  String firmId,
  ReportWindow window, {
  String? selected,
}) async {
  final sales = await _salesLines(db, firmId, window, selected);
  final purchases = await _purchaseLines(db, firmId, window, selected);
  // **The union, not one map's keys.** An item that was bought and never sold is
  // absent from the sales result, and an item sold and never bought is absent
  // from the purchase one — so iterating either alone drops half the catalogue
  // from an Item Wise P&L and makes the Purchases total short by exactly the
  // items nobody bought again.
  final out = <String, ItemTrading>{};
  for (final id in {...sales.keys, ...purchases.keys}) {
    out[id] = ItemTrading(
      saleQty: sales[id]?.saleQty ?? Decimal.zero,
      saleValue: sales[id]?.saleValue ?? Decimal.zero,
      saleTax: sales[id]?.saleTax ?? Decimal.zero,
      purchaseQty: purchases[id]?.purchaseQty ?? Decimal.zero,
      purchaseValue: purchases[id]?.purchaseValue ?? Decimal.zero,
      purchaseTax: purchases[id]?.purchaseTax ?? Decimal.zero,
    );
  }
  return out;
}

Future<Map<String, ItemTrading>> _salesLines(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  String? selected,
) async {
  final lines = db.salesInvoiceItems;
  final invoices = db.salesInvoices;
  final qty = lines.quantity.sum();
  final value = lines.taxableValue.sum();
  // Two aggregates **added** — `.sum()` on each is already a `SUM`, and
  // `SUM(SUM(a) + SUM(b))` is rejected by SQLite outright.
  final tax =
      lines.cgst.sum() +
      lines.sgst.sum() +
      lines.igst.sum() +
      lines.cessAmount.sum();
  final query = db.selectOnly(lines)
    ..join([innerJoin(invoices, invoices.id.equalsExp(lines.invoiceId))])
    ..addColumns([lines.itemId, invoices.docType, qty, value, tax])
    ..where(
      invoices.firmId.equals(firmId) &
          invoices.docType.isIn(const ['invoice', 'credit_note']) &
          ReportFilters.isLive(
            status: invoices.status,
            isDeleted: invoices.isDeleted,
          ) &
          ReportFilters.within(invoices.invoiceDate, window) &
          itemScope(lines.itemId, selected),
    )
    ..groupBy([lines.itemId, invoices.docType]);

  final out = <String, ItemTrading>{};
  for (final row in await query.get()) {
    final itemId = row.read(lines.itemId);
    if (itemId == null) continue;
    final sign = Decimal.fromInt(signFor('${row.read(invoices.docType)}'));
    final m = out[itemId] ?? ItemTrading.zero;
    out[itemId] = ItemTrading(
      saleQty: m.saleQty + sign * dec(row.read(qty) ?? 0),
      saleValue: m.saleValue + sign * dec(row.read(value) ?? 0),
      saleTax: m.saleTax + sign * dec(row.read(tax) ?? 0),
      purchaseQty: m.purchaseQty,
      purchaseValue: m.purchaseValue,
      purchaseTax: m.purchaseTax,
    );
  }
  return out;
}

Future<Map<String, ItemTrading>> _purchaseLines(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  String? selected,
) async {
  final lines = db.purchaseBillItems;
  final bills = db.purchaseBills;
  final qty = lines.quantity.sum();
  final value = lines.taxableValue.sum();
  final tax =
      lines.cgst.sum() +
      lines.sgst.sum() +
      lines.igst.sum() +
      lines.cessAmount.sum();
  final query = db.selectOnly(lines)
    ..join([innerJoin(bills, bills.id.equalsExp(lines.billId))])
    ..addColumns([lines.itemId, bills.docType, qty, value, tax])
    ..where(
      bills.firmId.equals(firmId) &
          bills.docType.isIn(const ['bill', 'debit_note']) &
          ReportFilters.isLive(
            status: bills.status,
            isDeleted: bills.isDeleted,
          ) &
          ReportFilters.within(bills.billDate, window) &
          itemScope(lines.itemId, selected),
    )
    ..groupBy([lines.itemId, bills.docType]);

  final out = <String, ItemTrading>{};
  for (final row in await query.get()) {
    final itemId = row.read(lines.itemId);
    if (itemId == null) continue;
    final sign = Decimal.fromInt(signFor('${row.read(bills.docType)}'));
    final m = out[itemId] ?? ItemTrading.zero;
    out[itemId] = ItemTrading(
      saleQty: m.saleQty,
      saleValue: m.saleValue,
      saleTax: m.saleTax,
      purchaseQty: m.purchaseQty + sign * dec(row.read(qty) ?? 0),
      purchaseValue: m.purchaseValue + sign * dec(row.read(value) ?? 0),
      purchaseTax: m.purchaseTax + sign * dec(row.read(tax) ?? 0),
    );
  }
  return out;
}

/// Says which items' profit is not a real figure.
///
/// The one thing every margin in this folder depends on: an item with sales and
/// no cost has a 100% margin, which reads as the best-selling product in the
/// firm and is the most expensive kind of wrong number this app can print.
List<String> uncostedNote(List<String> names) {
  if (names.isEmpty) return const [];
  final shown = names.take(5).join(', ');
  final more = names.length > 5 ? ' and ${names.length - 5} more' : '';
  return [
    'No cost of goods recorded for $shown$more — their margin is not a real '
        'figure. Cost the items (Stock report), then reopen this report.',
  ];
}

/// Coerces a `double` from SQLite into a [Decimal].
///
/// `double`, not `num`: drift returns `double` from a `REAL` column, and
/// `Decimal.fromInt` on it would throw rather than truncate — which is the right
/// failure, since a truncated rupee is a wrong number rather than an ugly one.
Decimal dec(Object? value) => Decimal.parse(value.toString());
