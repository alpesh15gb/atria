import 'package:flutter/foundation.dart';

import '../../database/app_database.dart';
import '../engine/report_result.dart';
import '../engine/report_runner.dart';
import '../engine/report_source.dart';
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
    return const ReportRunner().fold(
      spec: spec,
      window: window,
      rows: rows,
      groupKeyOf: groupKey == null ? null : (row) => groupKey(row),
      groupLabelOf: _labelFn(source.groupLabelFor(spec)),
      sortKeyOf: source.sortKeyFor(spec),
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
  static final List<ReportDefinition> _transaction = [
    _placeholder('sale', 'Sale', ReportCategory.transaction),
    _placeholder('purchase', 'Purchase', ReportCategory.transaction),
    _placeholder('day_book', 'Day Book', ReportCategory.transaction),
    _placeholder(
      'all_transactions',
      'All Transactions',
      ReportCategory.transaction,
    ),
    _placeholder(
      'profit_and_loss',
      'Profit And Loss',
      ReportCategory.transaction,
      layout: ReportLayout.document,
    ),
    _placeholder(
      'bill_wise_profit',
      'Bill Wise Profit',
      ReportCategory.transaction,
    ),
    _placeholder(
      'cash_flow',
      'Cash flow',
      ReportCategory.transaction,
      layout: ReportLayout.document,
    ),
    _placeholder(
      'trial_balance',
      'Trial Balance Report',
      ReportCategory.transaction,
      layout: ReportLayout.document,
    ),
    _placeholder(
      'balance_sheet',
      'Balance Sheet',
      ReportCategory.transaction,
      layout: ReportLayout.document,
    ),
  ];

  // ---- Party (6) ----
  static final List<ReportDefinition> _party = [
    _placeholder('party_statement', 'Party Statement', ReportCategory.party),
    _placeholder('party_wise_pnl', 'Party wise P&L', ReportCategory.party),
    _placeholder('all_parties', 'All parties', ReportCategory.party),
    _placeholder(
      'party_report_by_item',
      'Party Report By Item',
      ReportCategory.party,
    ),
    _placeholder(
      'sale_purchase_by_party',
      'Sale Purchase By Party',
      ReportCategory.party,
    ),
    _placeholder(
      'sale_purchase_by_party_group',
      'Sale Purchase By Party Group',
      ReportCategory.party,
    ),
  ];

  // ---- GST (6) ----
  static final List<ReportDefinition> _gst = [
    _placeholder(
      'gstr1',
      'GSTR 1',
      ReportCategory.gst,
      layout: ReportLayout.document,
    ),
    // The reference menu calls this GSTR 2. GSTR-2 is auto-populated by the
    // portal from suppliers' returns — no application can produce it. This slot
    // ships as GSTR-2A Reconciliation, which is real work the app already does,
    // and the screen says so rather than printing a fake return.
    _placeholder(
      'gstr2a_reconciliation',
      'GSTR-2A Reconciliation',
      ReportCategory.gst,
    ),
    _placeholder(
      'gstr3b',
      'GSTR 3B',
      ReportCategory.gst,
      layout: ReportLayout.document,
    ),
    _placeholder(
      'gstr9',
      'GSTR 9',
      ReportCategory.gst,
      layout: ReportLayout.document,
    ),
    _placeholder(
      'sale_summary_by_hsn',
      'Sale Summary By HSN',
      ReportCategory.gst,
    ),
    _placeholder('sac_report', 'SAC Report', ReportCategory.gst),
  ];

  // ---- Item/Stock (11) ----
  static final List<ReportDefinition> _itemStock = [
    _placeholder('stock_summary', 'Stock summary', ReportCategory.itemStock),
    _placeholder(
      'item_report_by_party',
      'Item Report By Party',
      ReportCategory.itemStock,
    ),
    _placeholder('item_wise_pnl', 'Item Wise P&L', ReportCategory.itemStock),
    _placeholder(
      'item_category_pnl',
      'Item Category Wise P&L',
      ReportCategory.itemStock,
    ),
    _placeholder(
      'low_stock_summary',
      'Low Stock Summary',
      ReportCategory.itemStock,
    ),
    _placeholder(
      'stock_detail',
      'Stock Detail',
      ReportCategory.itemStock,
      layout: ReportLayout.document,
    ),
    _placeholder('item_detail', 'Item Detail', ReportCategory.itemStock),
    _placeholder(
      'sp_by_item_category',
      'Sale/Purchase Report By Item Category',
      ReportCategory.itemStock,
    ),
    _placeholder(
      'stock_by_item_category',
      'Stock Summary Report By Item Category',
      ReportCategory.itemStock,
    ),
    _placeholder(
      'item_wise_discount',
      'Item Wise Discount',
      ReportCategory.itemStock,
    ),
    _placeholder(
      'stock_transfer',
      'Stock Transfer Report',
      ReportCategory.itemStock,
    ),
  ];

  // ---- Business Status (2) ----
  static final List<ReportDefinition> _businessStatus = [
    _placeholder(
      'bank_statement',
      'Bank Statement',
      ReportCategory.businessStatus,
    ),
    _placeholder(
      'discount_report',
      'Discount Report',
      ReportCategory.businessStatus,
    ),
  ];

  // ---- Taxes (6) ----
  static final List<ReportDefinition> _taxes = [
    _placeholder('gst_report', 'GST Report', ReportCategory.taxes),
    _placeholder('gst_rate_report', 'GST Rate Report', ReportCategory.taxes),
    _placeholder('form_27eq', 'Form No. 27EQ', ReportCategory.taxes),
    _placeholder('tcs_receivable', 'TCS Receivable', ReportCategory.taxes),
    _placeholder('tds_payable', 'TDS Payable', ReportCategory.taxes),
    _placeholder('tds_receivable', 'TDS Receivable', ReportCategory.taxes),
  ];

  // ---- Expense (3) ----
  static final List<ReportDefinition> _expense = [
    _placeholder('expense', 'Expense', ReportCategory.expense),
    _placeholder(
      'expense_category',
      'Expense Category Report',
      ReportCategory.expense,
    ),
    _placeholder('expense_item', 'Expense Item Report', ReportCategory.expense),
  ];

  // ---- S/P Order (2) ----
  static final List<ReportDefinition> _order = [
    _placeholder('sp_orders', 'Sale/Purchase Orders', ReportCategory.order),
    _placeholder(
      'sp_order_items',
      'Sale/Purchase Order Item',
      ReportCategory.order,
    ),
  ];

  // ---- Loan (1) ----
  static final List<ReportDefinition> _loan = [
    _placeholder('loan_statement', 'Loan Statement', ReportCategory.loan),
  ];

  static ReportDefinition _placeholder(
    String id,
    String title,
    ReportCategory category, {
    ReportLayout layout = ReportLayout.rows,
    ReportGroupBy groupBy = ReportGroupBy.none,
  }) {
    final spec = ReportSpec(
      id: id,
      title: title,
      category: category.label,
      columns: const [
        ReportColumn(key: 'label', label: 'Description'),
        ReportColumn(
          key: 'amount',
          label: 'Amount',
          kind: ReportValueKind.money,
        ),
      ],
      layout: layout,
      groupBy: groupBy,
    );
    return ReportDefinition(spec: spec, source: PlaceholderReportSource(id));
  }
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
