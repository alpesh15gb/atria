import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import '../transaction/transaction_common.dart';
import 'party_common.dart';

/// **Sale Purchase By Party** — the two-way ledger of every counterparty.
///
/// The report a shopkeeper uses to answer "do I only sell to this firm, or do I
/// buy from them too?" — a customer who is also a supplier is a different
/// relationship from a walk-in, and the two columns side by side are the only
/// way to see it without opening two registers.
///
/// **Taxable value and tax are separate columns, deliberately.** A GST return is
/// filed on the taxable value and the tax is computed *from* it, so a report
/// that printed only the total could not be used to check a return — the reader
/// would have to back out the tax by hand, and would do it at the wrong rate the
/// first time a document was exempt.
///
/// **Discount is its own column because it is money the firm gave away.** It is
/// `item_discount + invoice_discount_amount`, and printing only the line-level
/// one understates it by the header discount on every discounted invoice — the
/// exact split `discountOf` documents.
///
/// **The Net column is the trading relationship, not a margin**, and the footnote
/// says so: subtracting purchases from sales for a party you only buy from gives
/// a large negative number that looks like a loss and is not one.
const ReportSpec salePurchaseByPartySpec = ReportSpec(
  id: 'sale_purchase_by_party',
  title: 'Sale Purchase By Party',
  category: 'Party',
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
    ReportColumn(key: 'party', label: 'Party', flex: 3, emphasise: true),
    ReportColumn(
      key: 'saleValue',
      label: 'Sale value',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(key: 'saleTax', label: 'Sale tax', kind: ReportValueKind.money),
    ReportColumn(key: 'saleDiscount', label: 'Sale discount', wideOnly: true),
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
      key: 'purchaseDiscount',
      label: 'Purchase discount',
      wideOnly: true,
    ),
    ReportColumn(
      key: 'net',
      label: 'Net (sale − purchase)',
      kind: ReportValueKind.money,
      wideOnly: true,
    ),
  ],
  footnote:
      'Values are taxable — GST is shown in its own column, not folded in. Net '
      'is what you sold this party less what you bought from them; it is not a '
      'profit, and for a party you only buy from it is simply the negative of '
      'your purchases.',
);

const ReportDefinition salePurchaseByParty = ReportDefinition(
  spec: salePurchaseByPartySpec,
  source: CallbackReportSource(
    sourceId: 'sale_purchase_by_party',
    query: salePurchaseByPartyRows,
    options: partyOptions,
  ),
);

Future<List<ReportRow>> salePurchaseByPartyRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedPartyId(filters);
  final money = await partyMoney(db, firmId, window, selected: selected);
  final discounts = await _discountsByParty(db, firmId, window, selected);

  // The union, not `sales.keys` — a supplier has no sales and would vanish
  // from a report whose entire purpose is showing the two sides against each
  // other. This is the same union `partyWisePnlRows` builds, and it is why the
  // two reports total to the same figures.
  final ids = <String>{
    ...money.sales.keys,
    ...money.purchases.keys,
    ...money.salesTax.keys,
    ...money.purchaseTax.keys,
  };
  if (ids.isEmpty) return const [];

  final parties = await partiesById(db, firmId, ids.toList());
  final rows = <ReportRow>[];
  for (final id in ids) {
    final party = parties[id];
    if (party == null) continue;
    final saleValue = money.sales[id] ?? Decimal.zero;
    final purchaseValue = money.purchases[id] ?? Decimal.zero;
    rows.add(
      ReportRow({
        'party': party.name,
        'saleValue': saleValue,
        'saleTax': money.salesTax[id] ?? Decimal.zero,
        'saleDiscount': discounts.sales[id] ?? Decimal.zero,
        'purchaseValue': purchaseValue,
        'purchaseTax': money.purchaseTax[id] ?? Decimal.zero,
        'purchaseDiscount': discounts.purchases[id] ?? Decimal.zero,
        'net': saleValue - purchaseValue,
      }, label: party.name),
    );
  }
  return rows;
}

/// Σ discount given, per party, on each side.
///
/// A separate query because discount lives in columns the aggregate in
/// `partyMoney` does not touch.
///
/// **Grouped by `docType` as well as party, and signed in Dart — for the same
/// reason the tax is.** Every document on these tables stores its discount
/// columns **positive**, including a credit note: the engine took a positive
/// `discountAmount` off a line whose quantity and rate were themselves reduced,
/// so each of the two numbers is positive on its own and only their combination
/// carries the sign. Summing them unsigned therefore reports a customer who
/// *returned* ₹40 of discount as having been given ₹140, and the discount column
/// grows in exactly the months when customers came back — the one month a reader
/// most wants it to be honest.
///
/// The `SUM` arrives without the document's identity attached, so the sign
/// cannot be applied in SQL without putting an accounting rule inside a string;
/// `docType` comes back from the grouping and decides it here instead.
Future<({Map<String, Decimal> sales, Map<String, Decimal> purchases})>
_discountsByParty(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  String? selected,
) async {
  final invoices = db.salesInvoices;
  // Two aggregates **added** — `.sum()` on each is already a `SUM`, and wrapping
  // their sum in another `.sum()` emits `SUM(SUM(a) + SUM(b))`, which SQLite
  // rejects with "misuse of aggregate function".
  final saleDiscount =
      invoices.itemDiscount.sum() + invoices.invoiceDiscountAmount.sum();
  final salesQuery = db.selectOnly(invoices)
    ..addColumns([invoices.partyId, invoices.docType, saleDiscount])
    ..where(
      liveSalesIn(window, firmId, invoices) & partyScope(invoices.partyId, selected),
    )
    ..groupBy([invoices.partyId, invoices.docType]);

  final bills = db.purchaseBills;
  final purchaseDiscount =
      bills.itemDiscount.sum() + bills.invoiceDiscountAmount.sum();
  final purchaseQuery = db.selectOnly(bills)
    ..addColumns([bills.partyId, bills.docType, purchaseDiscount])
    ..where(
      livePurchasesIn(window, firmId, bills) &
          partyScope(bills.partyId, selected),
    )
    ..groupBy([bills.partyId, bills.docType]);

  final sales = <String, Decimal>{};
  for (final row in await salesQuery.get()) {
    final id = row.read(invoices.partyId);
    if (id == null) continue;
    sales[id] = (sales[id] ?? Decimal.zero) +
        Decimal.fromInt(signFor('${row.read(invoices.docType)}')) *
            dec(row.read(saleDiscount) ?? 0);
  }
  final purchases = <String, Decimal>{};
  for (final row in await purchaseQuery.get()) {
    final id = row.read(bills.partyId);
    if (id == null) continue;
    purchases[id] = (purchases[id] ?? Decimal.zero) +
        Decimal.fromInt(signFor('${row.read(bills.docType)}')) *
            dec(row.read(purchaseDiscount) ?? 0);
  }
  return (sales: sales, purchases: purchases);
}
