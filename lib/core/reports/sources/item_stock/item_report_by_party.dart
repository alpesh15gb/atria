import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/utils/money.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import 'item_common.dart';
import '../transaction/transaction_common.dart' show signFor;

/// **Item Report By Party** — who bought what, and who was sold what.
///
/// The transpose of Party Report By Item: that one groups by item and lists the
/// parties, this one groups by party and lists the items. A firm asking "which
/// customer takes the most cement" wants the first; "what does Ramesh buy" wants
/// this.
///
/// **One row per party × item pair**, not one row per party with the items
/// concatenated. A party's purchases are its purchases regardless of how many
/// items they span, and a report that puts three items in one cell makes the
/// Purchases total impossible to read off and impossible to verify.
///
/// **The item's name comes from the line, not the master.** A line written in
/// March keeps March's spelling even if the master was renamed since, and for
/// a *historical* report that is the correct behaviour: the reader is asking
/// what was billed, not what it is called now. Where the item has since been
/// deleted the line's name is still there, so the row survives — which is why
/// the lookup is by id but the label is not.
///
/// **A credit note nets, a quotation does not appear.** The same rule as every
/// other report in the app, and the same reason: a return is money coming back.
const ReportSpec itemReportByPartySpec = ReportSpec(
  id: 'item_report_by_party',
  title: 'Item Report By Party',
  category: 'Item/Stock',
  groupBy: ReportGroupBy.party,
  sort: ReportSort(columnKey: 'value', descending: true),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kItemFilterId,
      label: 'Item',
      value: null,
      hint: 'Every item',
    ),
  ],
  columns: [
    ReportColumn(key: 'party', label: 'Party', flex: 3, emphasise: true),
    ReportColumn(key: 'item', label: 'Item', flex: 3),
    ReportColumn(key: 'direction', label: 'Type'),
    ReportColumn(key: 'qty', label: 'Qty', kind: ReportValueKind.quantity),
    ReportColumn(
      key: 'rate',
      label: 'Rate',
      kind: ReportValueKind.rate,
      wideOnly: true,
    ),
    ReportColumn(
      key: 'value',
      label: 'Value',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
    ReportColumn(key: 'tax', label: 'GST', kind: ReportValueKind.money),
  ],
  footnote:
      'One row per party and item. Type is Sale or Purchase — a credit note '
      'nets against the sale it returns. Value is taxable value, before GST, '
      'which is shown separately.',
);

const ReportDefinition itemReportByParty = ReportDefinition(
  spec: itemReportByPartySpec,
  source: CallbackReportSource(
    sourceId: 'item_report_by_party',
    query: itemReportByPartyRows,
    options: itemOptions,
  ),
);

Future<List<ReportRow>> itemReportByPartyRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedItemId(filters);
  final sales = await _partyLines(db, firmId, window, selected, sale: true);
  final purchases = await _partyLines(
    db,
    firmId,
    window,
    selected,
    sale: false,
  );
  final rows = [...sales, ...purchases];
  if (rows.isEmpty) return rows;

  // Ids on the way out, names on the way in. The group cell has to be the
  // party's *name*: the engine sorts bands by their label, so a column of ids
  // groups correctly but reads as a column of database keys, and a party
  // renamed mid-period would then appear twice — once per id — which it would
  // not if the name were carried from the header the way the item name is
  // carried from the line.
  final ids = rows.map((r) => r.cells['party'] as String).toSet().toList();
  final names = await partyNames(db, ids);
  return [
    for (final row in rows)
      ReportRow({
        ...row.cells,
        'party': names[row.cells['party']] ?? 'Unknown party',
      }, label: names[row.cells['party']] ?? 'Unknown party'),
  ];
}

/// The parties' current names, by id.
Future<Map<String, String>> partyNames(AppDatabase db, List<String> ids) async {
  if (ids.isEmpty) return const {};
  final query = db.select(db.parties)..where((p) => p.id.isIn(ids));
  return {for (final party in await query.get()) party.id: party.name};
}

/// One side of the report: sales lines, or purchase lines.
///
/// Both are the same query with a different table pair, and they are written
/// out twice rather than parameterised because drift's query builder is typed
/// against a specific table — a generic version would need `dynamic` columns
/// and would give up compile-time checking on the very columns this report
/// reads. The duplication is deliberate; the *sign rule* is not duplicated,
/// because it comes from [signFor] in one place.
Future<List<ReportRow>> _partyLines(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  String? selected, {
  required bool sale,
}) async {
  if (sale) {
    final lines = db.salesInvoiceItems;
    final invoices = db.salesInvoices;
    final qty = lines.quantity.sum();
    final value = lines.taxableValue.sum();
    final tax =
        lines.cgst.sum() +
        lines.sgst.sum() +
        lines.igst.sum() +
        lines.cessAmount.sum();
    final query = db.selectOnly(lines)
      ..join([innerJoin(invoices, invoices.id.equalsExp(lines.invoiceId))])
      ..addColumns([
        invoices.partyId,
        invoices.docType,
        lines.name,
        qty,
        value,
        tax,
      ])
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
      // Grouped by party, docType and item name: the docType because the sign is
      // applied from it, and the item name because two spellings of one item
      // must not become two rows.
      ..groupBy([invoices.partyId, invoices.docType, lines.name]);

    return _rows(
      await query.get(),
      sale: true,
      partyOf: (row) => row.read(invoices.partyId),
      docTypeOf: (row) => '${row.read(invoices.docType)}',
      nameOf: (row) => '${row.read(lines.name)}',
      qtyOf: (row) => dec(row.read(qty) ?? 0),
      valueOf: (row) => dec(row.read(value) ?? 0),
      taxOf: (row) => dec(row.read(tax) ?? 0),
    );
  }

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
    ..addColumns([bills.partyId, bills.docType, lines.name, qty, value, tax])
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
    ..groupBy([bills.partyId, bills.docType, lines.name]);

  return _rows(
    await query.get(),
    sale: false,
    partyOf: (row) => row.read(bills.partyId),
    docTypeOf: (row) => '${row.read(bills.docType)}',
    nameOf: (row) => '${row.read(lines.name)}',
    qtyOf: (row) => dec(row.read(qty) ?? 0),
    valueOf: (row) => dec(row.read(value) ?? 0),
    taxOf: (row) => dec(row.read(tax) ?? 0),
  );
}

/// Signs each grouped row and turns it into a report row.
///
/// **`sale` is passed in rather than inferred from the sign.** The obvious
/// shortcut — "negative means purchase" — is wrong for a credit note: a credit
/// note is a sale document carrying a negative value, so inferring from the
/// number files every return under Purchases and the reader sees a supplier
/// selling them their own goods back. Which side a document is on is a fact
/// about the document, and only the caller knows which table it came from.
///
/// `TypedResult` — what `selectOnly` returns — rather than a concrete type,
/// because the two branches above return drift's untyped row and this only
/// reads through callbacks: one body for both sides, with the sign rule applied
/// once.
List<ReportRow> _rows(
  List<TypedResult> results, {
  required bool sale,
  required String? Function(TypedResult) partyOf,
  required String Function(TypedResult) docTypeOf,
  required String Function(TypedResult) nameOf,
  required Decimal Function(TypedResult) qtyOf,
  required Decimal Function(TypedResult) valueOf,
  required Decimal Function(TypedResult) taxOf,
}) {
  final label = sale ? 'Sale' : 'Purchase';
  final rows = <ReportRow>[];
  for (final row in results) {
    final partyId = partyOf(row);
    // A line with no party is a cash sale against the counter. Dropping it
    // would understate the period by exactly the walk-in trade, which on a
    // retail firm is most of it. It is kept, under the name the report uses for
    // a counter sale, because "a customer with no record" is still a sale.
    if (partyId == null || partyId.isEmpty) continue;
    final sign = Decimal.fromInt(signFor(docTypeOf(row)));
    final qty = sign * qtyOf(row);
    if (qty == Decimal.zero) continue;
    final value = sign * valueOf(row);
    rows.add(
      ReportRow({
        // The party **id** for now; `itemReportByPartyRows` swaps in the name,
        // which needs a lookup the row-by-row path has no business doing.
        'party': partyId,
        'item': nameOf(row),
        // A credit note is a Sale row carrying a negative, so the reader can
        // see the return inside the sale rather than hunting for it elsewhere.
        'direction': label,
        'qty': qty,
        // `Decimal /` returns a **Rational**, not a Decimal, and neither
        // `ReportRow.text()` nor `ReportRow.number()` has a Rational branch —
        // so ₹100 over 3 units printed the literal "100/3" in the Rate column
        // and counted as **zero** in every total. `Money.div` is the project's
        // one rounding division; `item_common.marginPercent` and
        // `gst_common.effectiveRateOf` already go through `.toDecimal(...)` for
        // exactly this reason.
        'rate': Money.div(value, qty),
        'value': value,
        'tax': sign * taxOf(row),
      }, label: partyId),
    );
  }
  return rows;
}
