import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/utils/money.dart';
import 'package:decimal/decimal.dart';

import 'party_common.dart';

/// **Sale Purchase By Party Group** — the same two-way ledger, rolled up by
/// segment.
///
/// The report a business with structure asks for: not "what did Buildmart buy"
/// but "what does my *construction* segment buy, and how much of the business is
/// that". The party grouping is a `Categories` row with `kind == 'party'` —
/// city, segment, channel, whatever the firm organises by — and it rides on
/// shipped schema v11, so nothing here needs a migration.
///
/// **Ungrouped is a row, not a gap.** `parties.categoryId` is nullable and null
/// means nobody has filed this customer yet, which is true of every party in
/// every firm until the feature is used. A roll-up that dropped them would total
/// short by exactly the parties nobody has got round to classifying — and the
/// reader, seeing a total that does not match the sum of the segments they *can*
/// see, has no way to know the customers are missing rather than quiet. It is
/// printed last so the classified groups read as the story and the residue reads
/// as a to-do.
///
/// **The figures come from the same [partyMoney] every other party report uses**,
/// aggregated up rather than recomputed. A segment total that disagreed with the
/// sum of its parties would be the single most confusing number in the folder,
/// because both would be right and there would be nothing to reconcile against.
const ReportSpec salePurchaseByPartyGroupSpec = ReportSpec(
  id: 'sale_purchase_by_party_group',
  title: 'Sale Purchase By Party Group',
  category: 'Party',
  groupBy: ReportGroupBy.category,
  sort: ReportSort(columnKey: 'saleValue', descending: true),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kPartyFilterId,
      label: 'Party',
      value: null,
      hint: 'Every party',
    ),
  ],
  columns: [
    ReportColumn(key: 'group', label: 'Party group', flex: 3, emphasise: true),
    ReportColumn(key: 'parties', label: 'Parties', kind: ReportValueKind.count),
    ReportColumn(
      key: 'saleValue',
      label: 'Sale value',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(key: 'saleTax', label: 'Sale tax', kind: ReportValueKind.money),
    ReportColumn(
      key: 'purchaseValue',
      label: 'Purchase value',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(
      key: 'purchaseTax',
      label: 'Purchase tax',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'net',
      label: 'Net (sale − purchase)',
      kind: ReportValueKind.money,
      wideOnly: true,
    ),
  ],
  footnote:
      'Groups are the party categories you have created. Every party not filed '
      'into one appears under "Ungrouped" — the total is never short of the '
      'parties in the business.',
);

const ReportDefinition salePurchaseByPartyGroup = ReportDefinition(
  spec: salePurchaseByPartyGroupSpec,
  source: CallbackReportSource(
    sourceId: 'sale_purchase_by_party_group',
    query: salePurchaseByPartyGroupRows,
    // The group name lives in `group`, and the default reader for
    // `ReportGroupBy.category` looks for `category`. Left to the convention every
    // row reads as missing and lands in one bucket named "?", so the report
    // collapses to a single "Subtotal" band sorted by value — the exact opposite
    // of the ordered segments it exists to show.
    groupKey: _groupName,
    notes: _partyGroupNotes,
    options: partyOptions,
  ),
);

/// The band's heading: the party group's own name.
String _groupName(ReportRow row) => '${row.cells['group'] ?? '?'}';

Future<List<ReportRow>> salePurchaseByPartyGroupRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedPartyId(filters);
  final money = await partyMoney(db, firmId, window, selected: selected);

  final ids = <String>{
    ...money.sales.keys,
    ...money.purchases.keys,
    ...money.salesTax.keys,
    ...money.purchaseTax.keys,
  };
  if (ids.isEmpty) return const [];

  final groups = await partyGroupNames(db, firmId, ids.toList());

  // One accumulator per group, keyed by the group's *display name*. Keying by
  // name rather than by `categoryId` is what makes "Ungrouped" a real bucket
  // alongside the real ones — there is no id for it, and inventing a sentinel id
  // is how a null category ends up as its own unlabelled group.
  final byGroup = <String, _GroupTotals>{};
  for (final id in ids) {
    final name = groups[id];
    // A party id with no record — a document whose party was hard-deleted — has
    // no group. Filing it under Ungrouped is right: it is a party the business
    // traded with and the total must include it.
    final key = name ?? 'Ungrouped';
    final totals = byGroup[key] ??= _GroupTotals(name: key);
    totals.parties += 1;
    totals.saleValue += money.sales[id] ?? Decimal.zero;
    totals.saleTax += money.salesTax[id] ?? Decimal.zero;
    totals.purchaseValue += money.purchases[id] ?? Decimal.zero;
    totals.purchaseTax += money.purchaseTax[id] ?? Decimal.zero;
  }

  final rows = <ReportRow>[];
  for (final totals in byGroup.values) {
    rows.add(
      ReportRow({
        'group': totals.name,
        'parties': Decimal.fromInt(totals.parties),
        'saleValue': totals.saleValue,
        'saleTax': totals.saleTax,
        'purchaseValue': totals.purchaseValue,
        'purchaseTax': totals.purchaseTax,
        'net': totals.saleValue - totals.purchaseValue,
      }, label: totals.name),
    );
  }

  // Ungrouped last regardless of value, so the classified segments read top-down
  // by size and the residue reads as what it is. The spec sorts on `saleValue`
  // within groups only — a `groupBy` never reorders its own groups — so this
  // ordering is the source's and has to be deliberate here.
  rows.sort((a, b) {
    final aUngrouped = a.cells['group'] == 'Ungrouped' ? 1 : 0;
    final bUngrouped = b.cells['group'] == 'Ungrouped' ? 1 : 0;
    return aUngrouped.compareTo(bUngrouped);
  });
  return rows;
}

/// A running total for one party group.
class _GroupTotals {
  _GroupTotals({required this.name});

  final String name;
  int parties = 0;
  Decimal saleValue = Decimal.zero;
  Decimal saleTax = Decimal.zero;
  Decimal purchaseValue = Decimal.zero;
  Decimal purchaseTax = Decimal.zero;
}

/// Say how much of the business is still unclassified.
///
/// Not a warning — a measurement. "Ungrouped: ₹4.2 lakh, 31 parties" is the
/// number that tells a firm its grouping is three-quarters done, and printing it
/// as a row *and* a note means it is visible whether the reader is scanning the
/// table or reading the messages above it.
List<String> _partyGroupNotes(ReportResult result) {
  final ungrouped = <ReportRow>[];
  for (final row in result.rows) {
    if (row.cells['group'] == 'Ungrouped') ungrouped.add(row);
  }
  if (ungrouped.isEmpty) return const [];

  final sales = ungrouped.fold<Decimal>(
    Decimal.zero,
    (sum, r) => sum + r.number(_saleValueColumn),
  );
  // Counted from the column rather than converted from it: `Decimal` has no
  // `toInt`, and a count does not need decimal precision in the first place.
  final count = ungrouped.fold<Decimal>(
    Decimal.zero,
    (sum, r) => sum + r.number(_partiesColumn),
  ).toStringAsFixed(0);
  return [
    '${Money.round2(sales).toStringAsFixed(2)} across $count '
        '${count == '1' ? 'party is' : 'parties are'} not filed into a group. '
        'They are included in the total; assigning them a group is what turns '
        'this report into a segment view.',
  ];
}

const ReportColumn _saleValueColumn = ReportColumn(
  key: 'saleValue',
  label: 'Sale value',
  kind: ReportValueKind.money,
);

const ReportColumn _partiesColumn = ReportColumn(
  key: 'parties',
  label: 'Parties',
  kind: ReportValueKind.count,
);
