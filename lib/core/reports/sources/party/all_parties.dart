import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import 'party_common.dart';

/// **All parties** — the master list, with what each party did in the period.
///
/// The one party report that is about the *parties* rather than about a
/// transaction: phone, GSTIN and city beside the figures, sorted so the biggest
/// balance is at the top. A shopkeeper uses it to find the customer they have
/// not called in four months, which is a question about the party and not about
/// a document.
///
/// **A party with no movement in the period is still listed**, with zeros. This
/// is the difference between this report and the other five: a filtered list of
/// parties who transacted is a *report of the period*, and a shopkeeper asking
/// "who are my customers" wants the *master*. Leaving idle parties out is how a
/// caller concludes a customer who bought nothing for a year has been deleted.
///
/// **It is not a statement.** Balances here are computed from the documents in
/// the window alone, so a party who owes ₹50,000 from last year and bought
/// nothing since shows zero. The Party Statement is the report that carries the
/// history forward, and the footnote says so rather than letting someone chase
/// an old debt from this screen.
const ReportSpec allPartiesSpec = ReportSpec(
  id: 'all_parties',
  title: 'All parties',
  category: 'Party',
  sort: ReportSort(columnKey: 'outstanding', descending: true),
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
    ReportColumn(key: 'type', label: 'Type'),
    ReportColumn(key: 'gstin', label: 'GSTIN', wideOnly: true),
    ReportColumn(key: 'phone', label: 'Phone', wideOnly: true),
    ReportColumn(key: 'city', label: 'City', wideOnly: true),
    ReportColumn(key: 'sales', label: 'Sales', kind: ReportValueKind.money),
    ReportColumn(
      key: 'purchases',
      label: 'Purchases',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'outstanding',
      label: 'Outstanding',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
  ],
  footnote:
      'Outstanding is this period\'s sales and purchases only, with no payments '
      'or earlier history — use Party Statement for what a party actually owes. '
      'A positive figure means the party owes you.',
);

const ReportDefinition allParties = ReportDefinition(
  spec: allPartiesSpec,
  source: CallbackReportSource(
    sourceId: 'all_parties',
    query: allPartiesRows,
    options: partyOptions,
  ),
);

Future<List<ReportRow>> allPartiesRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedPartyId(filters);
  final money = await partyMoney(db, firmId, window, selected: selected);

  // The master, not the movement. A party with no documents in the period has no
  // entry in `money` at all, and starting from `money` would list only the
  // parties who happened to trade — which is the whole reason this report exists
  // as separate from Party wise P&L.
  final query = db.select(db.parties)
    ..where(
      (_) =>
          db.parties.firmId.equals(firmId) &
          db.parties.isDeleted.equals(false) &
          (selected == null
              ? const Constant(true)
              : db.parties.id.equals(selected)),
    );

  final rows = <ReportRow>[];
  for (final party in await query.get()) {
    final sales = money.sales[party.id] ?? Decimal.zero;
    final purchases = money.purchases[party.id] ?? Decimal.zero;
    rows.add(
      ReportRow({
        'party': party.name,
        'type': _partyType(party.type),
        // The empty string rather than null: an unregistered walk-in customer has
        // no GSTIN, and a blank cell is a fact about them, not missing data.
        'gstin': party.gstin ?? '',
        'phone': party.phone ?? '',
        'city': party.city ?? '',
        'sales': sales,
        'purchases': purchases,
        // What they owe us, less what we owe them. A supplier who has been paid
        // less than we billed shows negative, and that negative is real — it is
        // a credit with the supplier, not an error.
        'outstanding': sales - purchases,
      }, label: party.name),
    );
  }
  return rows;
}

/// The label a shopkeeper recognises, not the stored slug.
String _partyType(String type) => switch (type) {
  'customer' => 'Customer',
  'supplier' => 'Supplier',
  'both' => 'Both',
  _ => type,
};
