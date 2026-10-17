import 'package:flutter/foundation.dart';

import '../../database/app_database.dart';
import '../engine/report_result.dart';
import '../engine/report_runner.dart';
import '../engine/report_source.dart';
import '../sources/gst/gstr2_purchase.dart';
import '../sources/business_status/bank_statement.dart';
import '../sources/business_status/discount_report.dart';
import '../sources/business_status/gst_rate_report.dart';
import '../sources/expense/expense_category_report.dart';
import '../sources/expense/expense_item_report.dart';
import '../sources/expense/expense_report.dart';
import '../sources/gst/gstr1.dart';
import '../sources/gst/gstr2a_reconciliation.dart';
import '../sources/gst/gstr3b.dart';
import '../sources/gst/gstr9.dart';
import '../sources/gst/sac_report.dart';
import '../sources/gst/sale_summary_by_hsn.dart';
import '../sources/item_stock/item_category_pnl.dart';
import '../sources/loan/loan_statement.dart';
import '../sources/order/sp_order_items.dart';
import '../sources/order/sp_orders.dart';
import '../sources/taxes/form_27eq.dart';
import '../sources/taxes/gst_report.dart';
import '../sources/taxes/tcs_receivable.dart';
import '../sources/taxes/tds_payable.dart';
import '../sources/taxes/tds_receivable.dart';
import '../sources/item_stock/item_detail.dart';
import '../sources/item_stock/item_report_by_party.dart';
import '../sources/item_stock/item_wise_discount.dart';
import '../sources/item_stock/item_wise_pnl.dart';
import '../sources/item_stock/low_stock_summary.dart';
import '../sources/item_stock/sp_by_item_category.dart';
import '../sources/item_stock/stock_by_item_category.dart';
import '../sources/item_stock/stock_detail.dart';
import '../sources/item_stock/stock_summary.dart';
import '../sources/item_stock/stock_transfer.dart';
import '../sources/party/all_parties.dart';
import '../sources/party/party_report_by_item.dart';
import '../sources/party/party_statement.dart';
import '../sources/party/party_wise_pnl.dart';
import '../sources/party/sale_purchase_by_party.dart';
import '../sources/party/sale_purchase_by_party_group.dart';
import '../sources/transaction/all_transactions.dart';
import '../sources/transaction/balance_sheet.dart';
import '../sources/transaction/bill_wise_profit.dart';
import '../sources/transaction/cash_flow.dart';
import '../sources/transaction/profit_and_loss.dart';
import '../sources/transaction/purchase_register.dart';
import '../sources/transaction/sale_register.dart';
import '../sources/transaction/trial_balance.dart';
import '../spec/report_spec.dart';
import '../window/report_window.dart';

/// The nine menu categories, in the order the reference menu shows them.
///
/// A category is a value rather than a string so a typo is a compile error, and
/// so "which reports are in Taxes" is a group-by rather than a filter over 47
/// hand-typed strings.
enum ReportCategory {
  transaction('Transaction'),
  party('Party'),
  gst('GST'),
  itemStock('Item/Stock'),
  businessStatus('Business Status'),
  taxes('Taxes'),
  expense('Expense'),
  order('S/P Order'),
  loan('Loan');

  const ReportCategory(this.label);

  final String label;
}

/// One entry in the catalogue: the declaration plus the way to fill it.
@immutable
class ReportDefinition {
  const ReportDefinition({required this.spec, required this.source});

  final ReportSpec spec;
  final ReportSource source;

  ReportCategory get category => categoryForSpec(spec);

  /// Run this report and fold it.
  Future<ReportResult> run(
    AppDatabase db,
    String firmId,
    ReportWindow window, {
    Map<String, Object?> filters = const {},
  }) async {
    final rows = await source.build(db, firmId, window, filters);
    final groupKey = source.groupKeyFor(spec);
    final folded = const ReportRunner().fold(
      spec: spec,
      window: window,
      rows: rows,
      groupKeyOf: groupKey == null ? null : (row) => groupKey(row),
      groupLabelOf: _labelFn(source.groupLabelFor(spec)),
      sortKeyOf: source.sortKeyFor(spec),
    );
    // Notes come last and see the folded result, because what a source has to
    // say is usually a disagreement the fold exposed.
    final notes = source.notesFor(spec);
    if (notes == null) return folded;
    return ReportResult(
      spec: folded.spec,
      window: folded.window,
      groups: folded.groups,
      grandTotals: folded.grandTotals,
      count: folded.count,
      notes: notes(folded),
    );
  }

  static String Function(ReportRow)? _labelFn(String Function(ReportRow)? fn) =>
      fn == null ? null : (row) => fn(row);

  /// The category a spec belongs to, parsed from its string.
  static ReportCategory categoryForSpec(ReportSpec spec) {
    for (final category in ReportCategory.values) {
      if (category.label == spec.category) return category;
    }
    return ReportCategory.transaction;
  }
}

/// Every report the app can produce, registered from day one.
///
/// **All 47 are listed, most pointing at an empty source.** That is the point:
/// "which reports are done" is a `grep` for a source that returns rows, not a
/// guess from a menu that silently omits the hard ones. A report registered
/// with an empty source shows an honest "not built yet" rather than being
/// absent — an absent report is a feature nobody asks for twice, and a stub
/// that prints zeros is worse than either.
class ReportCatalogue {
  const ReportCatalogue._();

  static final List<ReportDefinition> all = _build();

  /// Every id, for the route and for the tests that assert the count.
  static List<String> get ids =>
      all.map((d) => d.spec.id).toList(growable: false);

  static ReportDefinition? byId(String id) {
    for (final definition in all) {
      if (definition.spec.id == id) return definition;
    }
    return null;
  }

  static List<ReportDefinition> inCategory(ReportCategory category) =>
      all.where((d) => d.category == category).toList(growable: false);

  /// The menu, grouped for the categorized report screen.
  static Map<ReportCategory, List<ReportDefinition>> byCategory() {
    final map = <ReportCategory, List<ReportDefinition>>{};
    for (final category in ReportCategory.values) {
      final inIt = inCategory(category);
      if (inIt.isNotEmpty) map[category] = inIt;
    }
    return map;
  }

  /// The reports whose source actually returns rows.
  ///
  /// Everything else is registered but empty. Nothing in the app should count
  /// on this at runtime; it exists for the build.
  static List<ReportDefinition> get implemented => all
      .where((d) => d.source is! PlaceholderReportSource)
      .toList(growable: false);

  static List<ReportDefinition> _build() {
    final entries = <ReportDefinition>[
      ..._transaction,
      ..._party,
      ..._gst,
      ..._itemStock,
      ..._businessStatus,
      ..._taxes,
      ..._expense,
      ..._order,
      ..._loan,
    ];
    entries.sort((a, b) => a.spec.title.compareTo(b.spec.title));
    return entries;
  }

  // ---- Transaction (9) ----
  //
  // The first category to be built for real. Four of the nine are
  // `layout: document` and register a bespoke body under `features/reports/
  // documents/`; the other five come off the shared table.
  static final List<ReportDefinition> _transaction = [
    allTransactions,
    balanceSheet,
    billWiseProfit,
    cashFlow,
    dayBook,
    profitAndLoss,
    purchaseRegister,
    saleRegister,
    trialBalance,
  ];

  // ---- Party (6) ----
  //
  // The second category built for real, and the first whose reports are all
  // scoped by a **filter** rather than by their own window. Every one of them
  // shares `partyOptions`, so the picker offers the same list in the same order,
  // and opening Party Statement then Party Report By Item keeps the party.
  static final List<ReportDefinition> _party = [
    allParties,
    partyReportByItem,
    partyStatement,
    partyWisePnl,
    salePurchaseByParty,
    salePurchaseByPartyGroup,
  ];

  // ---- GST (6) ----
  //
  // The third category built for real. GSTR-1, 3B and 9 read
  // `GstReturnBuilder`, which is also what generates the portal JSON — so what
  // the screen shows and what gets uploaded are the same numbers by
  // construction, not by two implementations happening to agree.
  static final List<ReportDefinition> _gst = [
    gstr1,
    // The reference menu calls this GSTR 2. GSTR-2 is auto-populated by the
    // portal from suppliers' returns — no application can produce it. This slot
    // ships as GSTR-2A Reconciliation, which is real work the app already does,
    // and the screen says so rather than printing a fake return.
    gstr2aReconciliation,
    gstr2Purchase,
    gstr3b,
    gstr9,
    saleSummaryByHsn,
    sacReport,
  ];

  // ---- Item/Stock (11) ----
  static final List<ReportDefinition> _itemStock = [
    stockSummary,
    itemReportByParty,
    itemWisePnl,
    itemCategoryPnl,
    lowStockSummary,
    stockDetail,
    itemDetail,
    spByItemCategory,
    stockByItemCategory,
    itemWiseDiscount,
    stockTransfer,
  ];

  // ---- Business Status (2) ----
  static final List<ReportDefinition> _businessStatus = [
    bankStatement,
    discountReport,
  ];

  // ---- Taxes (6) ----
  //
  // GST Rate Report reads the rates actually charged on filed documents rather
  // than the rate configured on each item — that is the rate for the *next*
  // invoice, so reading it would erase every month sold at the old one.
  //
  // **TDS Receivable is still a placeholder, and the reason is the schema.**
  // `sales_invoices.tcs` is tax the firm *collected from* a customer — it is
  // added to the invoice's grand total — so it is the TCS Receivable report and
  // nothing else. "Tax a customer deducted from us" is a different fact, lives on
  // a different line of the return, and **no column anywhere stores it**. Wiring
  // the report to `tcs` would produce two identically-worded reports reading the
  // same number, which is worse than an honest empty one. It needs schema v13.
  static final List<ReportDefinition> _taxes = [
    gstReport,
    gstRateReport,
    form27eq,
    tcsReceivable,
    tdsPayable,
    tdsReceivable,
  ];

  // ---- Expense (3) ----
  static final List<ReportDefinition> _expense = [
    expenseReport,
    expenseCategoryReport,
    expenseItemReport,
  ];

  // ---- S/P Order (2) ----
  static final List<ReportDefinition> _order = [spOrders, spOrderItems];

  // ---- Loan (1) ----
  static final List<ReportDefinition> _loan = [loanStatement];
}

/// A registered report that has no implementation yet.
///
/// It returns **no rows**, never zero rows. A stub that returns a row of zeros
/// looks like a business that did nothing; an empty report looks like a
/// business with nothing to report. Only the second is honest.
class PlaceholderReportSource extends ReportSource {
  const PlaceholderReportSource(this.sourceId);

  @override
  final String sourceId;

  @override
  Future<List<ReportRow>> build(
    AppDatabase db,
    String firmId,
    ReportWindow window,
    Map<String, Object?> filters,
  ) async => const [];
}
