import 'package:decimal/decimal.dart';
// Not `show Value`: every predicate below is built from drift's expression
// operators (`|`, `&`, `not`) which live on extension types a narrowed import
// silently drops.
import 'package:drift/drift.dart' hide isNull;

import '../../../database/app_database.dart';
import '../../engine/report_source.dart';
import '../../spec/report_spec.dart';
import '../../window/report_window.dart';
import '../transaction/transaction_common.dart';

/// The party list, for a filter dropdown.
///
/// **The one place a firm's parties are read for the reports layer.** Every
/// party report needs the same list, and a report that built its own would sort
/// or search differently from the report beside it — so "Buildmart" appears
/// once in the picker and "Buildmart Supplies" in the other, and the reader
/// concludes the two reports cover different businesses.
///
/// Soft-deleted parties are excluded. A party in the recycle bin is a party the
/// firm no longer trades with, and offering it in a picker means a statement
/// that opens on somebody the user just deleted.
Future<List<ReportFilterOption<Object?>>> partyFilterOptions(
  AppDatabase db,
  String firmId,
) async {
  final parties =
      await (db.select(db.parties)
            ..where((p) => p.firmId.equals(firmId) & p.isDeleted.equals(false))
            ..orderBy([(p) => OrderingTerm.asc(p.name)]))
          .get();
  return [
    for (final party in parties)
      ReportFilterOption<Object?>(value: party.id, label: party.name),
  ];
}

/// The options callback every party report hands to its source.
///
/// **A named function, not a closure written inline in the `const`
/// `ReportDefinition`.** `Future.value(…)` is a method call and a call is not a
/// constant expression, so an inline `options: (db, firm, spec, id) => …` made
/// the whole definition fail to compile as `const` — which every other report in
/// the catalogue is, and which is what lets a spec be built in a test with no
/// fixture. One shared function also means all six party reports offer the same
/// list in the same order.
Future<List<ReportFilterOption<Object?>>> partyOptions(
  AppDatabase db,
  String firmId,
  ReportSpec spec,
  String filterId,
) => filterId == kPartyFilterId
    ? partyFilterOptions(db, firmId)
    : Future<List<ReportFilterOption<Object?>>>.value(const []);

/// The filter id every party-scoped report uses.
///
/// One id rather than one per report, so the picker, the empty state and the
/// export header all read the same key — and so resolving a party is one lookup
/// a source does, not five different spellings spread across six files. It also
/// means switching from Party Statement to Party Report By Item keeps the party,
/// which is what a reader expects when they are looking at the same customer two
/// ways.
const String kPartyFilterId = 'partyId';

/// The party named by [filters], or null for "every party".
///
/// **Null is a real, useful answer, not a missing value.** Every party report
/// here has both a per-party form and an all-parties form, and the all-parties
/// one is what a report screen should open on — a reader who opens "All
/// parties" wants the list, and one who wants a single customer opens the same
/// report and picks them. A source that treated null as an error would have to
/// invent a default party, and a statement of the wrong customer is worse than
/// the list of all of them.
String? selectedPartyId(Map<String, Object?> filters) {
  final value = filters[kPartyFilterId];
  if (value == null) return null;
  final id = '$value'.trim();
  return id.isEmpty ? null : id;
}

/// Restricts a party-keyed expression to the selected party, when one is.
///
/// The parameter is `Expression<String>` and not `Expression<String?>` because
/// drift's `equals` lives on the *non-null* extension type; a nullable column
/// reads as `Expression<String>` and compares fine.
Expression<bool> partyScope(Expression<String> partyId, String? selected) =>
    selected == null ? const Constant(true) : partyId.equals(selected);

/// Σ a signed measure and its tax per party, in two grouped queries.
///
/// **One pass over the sales side and one over the purchase side, rather than
/// one aggregate per report.** Six party reports ask the same questions of the
/// same two tables, and a report that ran its own aggregate would drift from its
/// neighbours the day someone corrected one of them — which is precisely how a
/// Party Statement and a Party wise P&L come to disagree about the same customer.
/// A CA who checks the two and finds a difference stops trusting both.
///
/// **Grouping by docType as well as partyId is load-bearing**, and it is why the
/// sign rule is applied here rather than in SQL. `SUM(taxable_value)` over a
/// party who has one invoice and one credit note cannot know which is which, so
/// it cannot decide whether to add or subtract. `SUM(CASE WHEN doc_type =
/// 'credit_note' THEN -v ELSE v END)` would work and would put an accounting
/// rule inside a SQL string where no test can read it.
///
/// [value] is **taxable value, never `grandTotal`**. Output tax is not revenue
/// and input tax credit is not a cost, so a P&L built on the invoice total
/// reports margin as a fraction of the tax. A *statement of account* is the one
/// deliberate exception — what a party owes necessarily includes the tax — which
/// is why that report uses `ReportRepository.partyStatement` rather than this.
class PartyMoney {
  const PartyMoney({
    required this.sales,
    required this.salesTax,
    required this.purchases,
    required this.purchaseTax,
  });

  /// Taxable value of invoices, less credit notes.
  final Map<String, Decimal> sales;

  /// Output tax on those documents.
  final Map<String, Decimal> salesTax;

  /// Taxable value of bills, less debit notes.
  final Map<String, Decimal> purchases;

  /// Input tax on those documents.
  final Map<String, Decimal> purchaseTax;

  static const PartyMoney empty = PartyMoney(
    sales: {},
    salesTax: {},
    purchases: {},
    purchaseTax: {},
  );

  bool get isEmpty =>
      sales.isEmpty &&
      purchases.isEmpty &&
      salesTax.isEmpty &&
      purchaseTax.isEmpty;
}

/// The live figures behind every party report in this folder.
Future<PartyMoney> partyMoney(
  AppDatabase db,
  String firmId,
  ReportWindow window, {
  String? selected,
}) async {
  final sales = await _salesAggregate(db, firmId, window, selected);
  final purchases = await _purchaseAggregate(db, firmId, window, selected);
  return PartyMoney(
    sales: sales.value,
    salesTax: sales.tax,
    purchases: purchases.value,
    purchaseTax: purchases.tax,
  );
}

Future<({Map<String, Decimal> value, Map<String, Decimal> tax})>
_salesAggregate(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  String? selected,
) async {
  final invoices = db.salesInvoices;
  final taxable = invoices.taxableValue.sum();
  // Four `SUM`s **added**, not a `SUM` of them: `.sum()` on each column already
  // produces an aggregate, and wrapping the sum of those in another `.sum()`
  // emits `SUM(SUM(cgst) + SUM(sgst) + …)`, which SQLite rejects outright with
  // "misuse of aggregate function" — the query fails rather than returning a
  // wrong number, which is at least honest.
  //
  // `cess`, not `cessAmount`: the latter is the *line* table's spelling and does
  // not exist on a document header.
  final tax =
      invoices.cgst.sum() +
      invoices.sgst.sum() +
      invoices.igst.sum() +
      invoices.cess.sum();
  final query = db.selectOnly(invoices)
    ..addColumns([invoices.partyId, invoices.docType, taxable, tax])
    ..where(
      liveSalesIn(window, firmId, invoices) &
          partyScope(invoices.partyId, selected),
    )
    ..groupBy([invoices.partyId, invoices.docType]);

  return _collect(query, taxable, tax, invoices.partyId, invoices.docType);
}

Future<({Map<String, Decimal> value, Map<String, Decimal> tax})>
_purchaseAggregate(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  String? selected,
) async {
  final bills = db.purchaseBills;
  final taxable = bills.taxableValue.sum();
  // Four aggregates added, for the reason the sales-side comment gives.
  final tax =
      bills.cgst.sum() + bills.sgst.sum() + bills.igst.sum() + bills.cess.sum();
  final query = db.selectOnly(bills)
    ..addColumns([bills.partyId, bills.docType, taxable, tax])
    ..where(
      livePurchasesIn(window, firmId, bills) &
          partyScope(bills.partyId, selected),
    )
    ..groupBy([bills.partyId, bills.docType]);

  return _collect(query, taxable, tax, bills.partyId, bills.docType);
}

/// Turns a `(partyId, docType) GROUP BY` into the two maps the reports want.
///
/// **Both halves of the pair are signed, and the tax half is the one that is
/// easy to miss.** A credit note stores its GST columns **positive** — the
/// engine wrote them from a positive line on a document whose *name* means
/// "reduce" — so an unsigned `Σ cgst` over one invoice and one credit note
/// returns the tax on both. Output tax then exceeds what was ever collected, and
/// a GSTR-1 built off this figure over-states the liability by exactly the
/// returned amount.
///
/// The value half signs explicitly; the tax half could not, because `SUM` of the
/// four GST columns arrives as one already-summed number with the document's
/// identity no longer attached to it. Both are therefore signed in Dart from the
/// `docType` the query also groups by.
Future<({Map<String, Decimal> value, Map<String, Decimal> tax})> _collect(
  Selectable<dynamic> query,
  Expression<double> taxable,
  Expression<double> tax,
  Expression<String> partyId,
  Expression<String> docType,
) async {
  final value = <String, Decimal>{};
  final taxes = <String, Decimal>{};
  for (final row in await query.get()) {
    final id = row.read(partyId);
    if (id == null) continue;
    final type = '${row.read(docType)}';
    final sign = Decimal.fromInt(signFor(type));
    value[id] =
        (value[id] ?? Decimal.zero) + sign * dec(row.read(taxable) ?? 0);
    taxes[id] = (taxes[id] ?? Decimal.zero) + sign * dec(row.read(tax) ?? 0);
  }
  return (value: value, tax: taxes);
}

/// The party's own record, for the name, GSTIN and phone a report prints beside
/// their figures.
Future<Map<String, PartyEntity>> partiesById(
  AppDatabase db,
  String firmId,
  List<String> ids,
) async {
  if (ids.isEmpty) return const {};
  // The query builder rather than `customSelect`, so a firm with two thousand
  // parties gets drift's `IN (…)` variable chunking instead of a
  // `too many SQL variables` at 999.
  final query = db.select(db.parties)
    ..where((p) => p.firmId.equals(firmId) & p.id.isIn(ids));
  return {for (final party in await query.get()) party.id: party};
}

/// The party-group name each party belongs to, or `Ungrouped`.
///
/// **Never null and never omitted.** `parties.categoryId` is nullable and null
/// means "nobody has grouped this customer yet" — true of every party in every
/// firm that has not set up groups, which is every firm until the feature is
/// used. A report that dropped them would total short by exactly those parties,
/// and the reader would have no way to know the customers were missing rather
/// than quiet.
Future<Map<String, String>> partyGroupNames(
  AppDatabase db,
  String firmId,
  List<String> ids,
) async {
  const ungrouped = 'Ungrouped';
  final parties = await partiesById(db, firmId, ids);
  final categoryIds = parties.values
      .map((p) => p.categoryId)
      .whereType<String>()
      .toSet()
      .toList();
  final names = <String, String>{};
  if (categoryIds.isNotEmpty) {
    final query = db.select(db.categories)
      ..where(
        (c) =>
            c.firmId.equals(firmId) &
            c.kind.equals('party') &
            c.id.isIn(categoryIds),
      );
    for (final category in await query.get()) {
      names[category.id] = category.name;
    }
  }
  return {
    for (final entry in parties.entries)
      entry.key: entry.value.categoryId == null
          ? ungrouped
          : names[entry.value.categoryId] ?? ungrouped,
  };
}

/// The stock cost of what was sold to each party.
///
/// **Per party, from the movements, not from the item's current price.**
/// `stock_movements.unitCost` is stamped at the moment the goods left, at the
/// weighted moving average of that moment (schema v11), so it answers *what did
/// this sale cost me* — the question a profit-by-customer report exists to
/// answer. Valuing it at today's rate makes last quarter's margin change because
/// somebody bought stock this week.
///
/// **The credit note is the trap, and the movement handles it.** The stock that
/// came back is a positive quantity against a positive cost, so the sum is the
/// negative of the original sale's cost and the margin mirrors exactly. Deriving
/// cost from a catalogue price instead would give the return a positive cost and
/// a margin of 100%.
///
/// A party missing from the result has **no sale in the window that left stock**,
/// which is not the same as a party whose goods were never costed. The caller
/// distinguishes them: an absent party is a note, a present party at zero cost
/// is a margin that must not be believed. Both cases are covered by the same
/// warning, because neither produces a real number.
Future<PartyCost> costOfGoodsByParty(
  AppDatabase db,
  String firmId,
  ReportWindow window, {
  String? selected,
}) async {
  // The movement knows which document it came from but not who that document was
  // for, so the join is by document id: one query for the invoices in the
  // window, one for the movements belonging to them.
  final invoices =
      await (db.select(db.salesInvoices)..where(
            (_) =>
                liveSalesIn(window, firmId, db.salesInvoices) &
                db.salesInvoices.partyId.isNotNull() &
                partyScope(db.salesInvoices.partyId, selected),
          ))
          .get();
  if (invoices.isEmpty) return PartyCost.none;

  final partyByInvoice = <String, String>{};
  for (final invoice in invoices) {
    final partyId = invoice.partyId;
    if (partyId != null) partyByInvoice[invoice.id] = partyId;
  }

  final cost = (db.stockMovements.quantity * db.stockMovements.unitCost).sum();
  final query = db.selectOnly(db.stockMovements)
    ..addColumns([db.stockMovements.sourceId, cost])
    ..where(
      db.stockMovements.firmId.equals(firmId) &
          db.stockMovements.source.equals('sales_invoices') &
          db.stockMovements.kind.isIn(const ['sale', 'sale_return']) &
          ReportFilters.within(db.stockMovements.date, window) &
          db.stockMovements.sourceId.isIn(partyByInvoice.keys.toList()),
    )
    ..groupBy([db.stockMovements.sourceId]);

  final out = <String, Decimal>{};
  // Two sets, because "sold goods that were never costed" and "did not sell"
  // look identical in [out] — both are absent — and they need opposite
  // treatment. The first is a margin that must not be believed and wants a note;
  // the second is simply not in the report.
  final moved = <String>{};
  final costed = <String>{};
  for (final row in await query.get()) {
    final invoiceId = row.read(db.stockMovements.sourceId);
    if (invoiceId == null) continue;
    final partyId = partyByInvoice[invoiceId];
    if (partyId == null) continue;
    final raw = row.read(cost) ?? 0;
    moved.add(partyId);
    // A movement with a genuinely zero cost is a *present* row with no cost in
    // it, which is different from no row at all — and it is the difference
    // between "costed at zero" and "never costed", so it has to be recorded.
    if (raw != 0) costed.add(partyId);
    // Negated: a sale's movement is a negative quantity against a positive cost,
    // so the raw sum is already the opposite of what the column prints.
    out[partyId] = (out[partyId] ?? Decimal.zero) - dec(raw);
  }
  return PartyCost(byParty: out, uncosted: moved.difference(costed));
}

/// A party's cost of goods sold, and which parties' is not a real figure.
class PartyCost {
  const PartyCost({required this.byParty, required this.uncosted});

  /// Cost per party. A party absent here either sold nothing that left stock, or
  /// is in [uncosted] — the two are told apart by the caller, which is the only
  /// reason this is a record rather than a bare map.
  final Map<String, Decimal> byParty;

  /// Parties that sold goods whose cost is zero, so their margin reads 100%.
  final Set<String> uncosted;

  static const PartyCost none = PartyCost(byParty: {}, uncosted: {});
}
