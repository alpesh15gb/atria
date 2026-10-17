import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/utils/money.dart';
import 'package:decimal/decimal.dart';

import 'party_common.dart';

/// **Party wise P&L** — what each customer actually earned.
///
/// The one party report where *profit* rather than *value* is the question, and
/// the answer cannot be the invoice total. A customer billed ₹1,180 at 18% GST
/// generated ₹1,000 of revenue, and the ₹180 is the government's money passing
/// through on the way. Reporting the total would make every margin read 18%
/// better than it is, and would make this report disagree with the P&L beside it
/// by exactly the output tax — which is the disagreement a CA looks for first
/// and concludes one of the two is wrong.
///
/// **The two sides do not agree, and that is correct.** Sales here are what the
/// firm *sold*; purchases are what it *bought*. A customer shows purchases of
/// zero and a supplier shows sales of zero, because a trader who is both gets
/// two numbers and a net that is not a margin. The report prints the net rather
/// than hiding one side, because "which customers do we also buy from" is a real
/// question this answers — and labels it so nobody reads it as profit.
///
/// **Cost is the movement's, not the catalogue's**, for the reason spelled out
/// in `costOfGoodsByParty`: a margin that changes because stock was bought
/// this week is not a margin.
const ReportSpec partyWisePnlSpec = ReportSpec(
  id: 'party_wise_pnl',
  title: 'Party wise P&L',
  category: 'Party',
  groupBy: ReportGroupBy.none,
  sort: ReportSort(columnKey: 'profit', descending: true),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kPartyFilterId,
      label: 'Party',
      value: null,
      hint: 'Every party',
    ),
  ],
  columns: [
    ReportColumn(key: 'party', label: 'Party', flex: 3, emphasise: true),
    ReportColumn(key: 'sales', label: 'Sales', kind: ReportValueKind.money),
    ReportColumn(
      key: 'cogs',
      label: 'Cost of goods',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(
      key: 'profit',
      label: 'Gross profit',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
    ReportColumn(key: 'margin', label: 'Margin', kind: ReportValueKind.percent),
    ReportColumn(
      key: 'purchases',
      label: 'Purchases',
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
      'Sales and purchases exclude GST. Gross profit is sales less the cost of '
      'the goods at the weighted average recorded when they left stock. '
      '"Net" is what the firm sold this party less what it bought from them — '
      'it is not a margin, and for a party that is only a supplier or only a '
      'customer it is simply the one number that is non-zero.',
);

const ReportDefinition partyWisePnl = ReportDefinition(
  spec: partyWisePnlSpec,
  source: CallbackReportSource(
    sourceId: 'party_wise_pnl',
    query: partyWisePnlRows,
    notes: _partyWisePnlNotes,
    options: partyOptions,
  ),
);

Future<List<ReportRow>> partyWisePnlRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedPartyId(filters);
  final money = await partyMoney(db, firmId, window, selected: selected);
  final cost = await costOfGoodsByParty(db, firmId, window, selected: selected);

  // A party who appears in only one of the maps is still a row. Collecting the
  // union rather than iterating `sales` alone is what keeps a supplier — who has
  // purchases and no sales — on the report at all, and dropping them would make
  // the Purchases total silently short by every supplier in the firm.
  final ids = <String>{
    ...money.sales.keys,
    ...money.purchases.keys,
    ...money.salesTax.keys,
    ...cost.byParty.keys,
  };
  if (ids.isEmpty) return const [];

  final parties = await partiesById(db, firmId, ids.toList());

  final rows = <ReportRow>[];
  for (final id in ids) {
    final party = parties[id];
    if (party == null) continue;
    final sales = money.sales[id] ?? Decimal.zero;
    final purchases = money.purchases[id] ?? Decimal.zero;
    final cogs = cost.byParty[id] ?? Decimal.zero;
    rows.add(
      ReportRow({
        'party': party.name,
        'sales': sales,
        'cogs': cogs,
        'profit': sales - cogs,
        // On **sales**, never on the invoice total. Dividing by the total folds
        // output GST into the denominator and understates every margin by the
        // tax rate — the same trap Bill Wise Profit documents.
        'margin': sales == Decimal.zero
            ? Decimal.zero
            : Money.div((sales - cogs) * Decimal.fromInt(100), sales),
        'purchases': purchases,
        'net': sales - purchases,
      }, label: party.name),
    );
  }
  return rows;
}

/// Say which parties' profit is not a real figure, and by how much the report
/// disagrees with the P&L.
List<String> _partyWisePnlNotes(ReportResult result) {
  final notes = <String>[];

  // A party with sales and no cost of goods has a 100% margin, which reads as
  // the best customer in the firm and is the most expensive kind of wrong
  // number this app can print.
  final uncosted = result.rows
      .where(
        (r) =>
            r.number(_salesColumn) > Decimal.zero &&
            r.number(_cogsColumn) == Decimal.zero,
      )
      .map((r) => '${r.cells['party']}')
      .toList();
  if (uncosted.isNotEmpty) {
    final shown = uncosted.take(5).join(', ');
    final more = uncosted.length > 5 ? ' and ${uncosted.length - 5} more' : '';
    notes.add(
      'No cost of goods recorded for $shown$more — their margin is not a real '
      'figure. Cost the items (Stock report), then reopen this report.',
    );
  }

  return notes;
}

const ReportColumn _salesColumn = ReportColumn(
  key: 'sales',
  label: 'Sales',
  kind: ReportValueKind.money,
);

const ReportColumn _cogsColumn = ReportColumn(
  key: 'cogs',
  label: 'Cost of goods',
  kind: ReportValueKind.money,
);
