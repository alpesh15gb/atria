import 'package:decimal/decimal.dart';
// Not `show Value`: `ReportFilters.within` and the `isIn`/`equals` predicates
// below are drift extension types, and a narrowed import drops them.
import 'package:drift/drift.dart' hide isNull;

import '../../../database/tables/purchases.dart';
import '../../../database/tables/sales_invoices.dart';
import '../../../utils/money.dart';
import '../../engine/report_source.dart';
import '../../window/report_window.dart';

/// A REAL column read as a [Decimal], exactly.
///
/// `Money.of(double)` goes through `Decimal.parse(v.toString())`, and SQLite's
/// REAL holds whatever arithmetic accumulated — `1234.5600000000001` for a
/// figure that is really ₹1,234.56. `Decimal.parse` copes with that, but some
/// doubles render as `"1.2345600000000001e3"`, which is not a number a
/// `Decimal.parse` should ever be handed. Rounding to 2dp with `toStringAsFixed`
/// *first* is the bridge.
///
/// The alternative — summing the doubles and converting once at the end — is
/// what `report_repository` does, and it is why its total can be a paisa out on
/// a report with a few thousand rows. Every source here converts per row and
/// accumulates in [Decimal].
Decimal dec(double value) => Money.parse(value.toStringAsFixed(2));

/// Output tax on a document, from its three GST columns plus cess.
///
/// Summed rather than selected because there is no `total_tax` column, and
/// adding them in `double` and rounding once would make a document with 18%
/// CGST and 18% SGST a paisa out for no visible reason.
Decimal outputTaxOf({
  required double cgst,
  required double sgst,
  required double igst,
  required double cess,
}) => dec(cgst) + dec(sgst) + dec(igst) + dec(cess);

/// The discount actually given on a document.
///
/// `item_discount` is the per-line reduction, `invoice_discount_amount` the
/// header reduction already apportioned across the lines by the engine. They are
/// different columns because they are different facts, and a report that
/// prints only one of them understates the discount by the other.
Decimal discountOf({
  required double itemDiscount,
  required double invoiceDiscount,
}) => dec(itemDiscount) + dec(invoiceDiscount);

/// The sales-side documents that are actual transactions.
///
/// A quotation, a sales order and a delivery note are **not** money and **not**
/// stock. Include them and the Trial Balance and the P&L disagree by every
/// pending quotation — and a stock report disagrees too, because `isDeleted` is
/// false on a quotation nobody has converted yet.
const List<String> kSalesDocTypes = ['invoice', 'credit_note'];

/// The purchase-side equivalents. A purchase order is not a bill.
const List<String> kPurchaseDocTypes = ['bill', 'debit_note'];

/// Both sides at once, for the two reports that union them.
const List<String> kAllDocTypes = [
  'invoice',
  'credit_note',
  'bill',
  'debit_note',
];

/// Every predicate a sales-side report must apply, in one expression.
///
/// Written once because the bounced/cancelled/deleted pair is exactly what a
/// tenth source drops by accident — and the report that drops it disagrees
/// with the Trial Balance by whatever it wrongly included, with nothing to say
/// so. "Live" is **not** one predicate: a document can be cancelled *and* be
/// in the recycle bin.
Expression<bool> liveSalesIn(
  ReportWindow window,
  String firmId,
  SalesInvoices firms, {
  List<String> docTypes = kSalesDocTypes,
}) =>
    firms.firmId.equals(firmId) &
    firms.docType.isIn(docTypes) &
    ReportFilters.isLive(status: firms.status, isDeleted: firms.isDeleted) &
    ReportFilters.within(firms.invoiceDate, window);

/// The same, for the purchase side.
Expression<bool> livePurchasesIn(
  ReportWindow window,
  String firmId,
  PurchaseBills bills, {
  List<String> docTypes = kPurchaseDocTypes,
}) =>
    bills.firmId.equals(firmId) &
    bills.docType.isIn(docTypes) &
    ReportFilters.isLive(status: bills.status, isDeleted: bills.isDeleted) &
    ReportFilters.within(bills.billDate, window);

/// A document's sign for a report that puts sales and purchases side by side.
///
/// A **credit note and a debit note are negative**, because they return goods
/// and money flows the other way. Storing them positive and reading them as
/// positive is the trap plan rule 1 names: `profitAndLoss` subtracts a credit
/// note from sales while `gstSummary` used to add it, so the P&L and the return
/// filed from the same books disagreed.
int signFor(String docType) =>
    (docType == 'credit_note' || docType == 'debit_note') ? -1 : 1;

/// The label a report prints in its Type column.
///
/// The document's own `docType` slug (`credit_note`) means nothing to a shop
/// owner; the name they wrote it under does.
String docTypeLabel(String docType) => switch (docType) {
  'invoice' => 'Sales invoice',
  'credit_note' => 'Credit note',
  'bill' => 'Purchase bill',
  'debit_note' => 'Debit note',
  'quotation' => 'Quotation',
  'sales_order' => 'Sales order',
  'delivery_note' => 'Delivery note',
  'purchase_order' => 'Purchase order',
  _ => docType,
};
