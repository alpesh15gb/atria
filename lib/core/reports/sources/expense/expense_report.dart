import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import '../transaction/transaction_common.dart';
import 'expense_common.dart';

/// **Expense** — the expense register for the window.
///
/// One row per business expense recorded in the period, grouped by month.
/// Shows the net expense cost (`amount − gstAmount` when ITC is eligible, or
/// full `amount` when unregistered / ineligible), the GST component, and the
/// total paid out, so the register reconciles with both the P&L and the cash
/// outflow.
const ReportSpec expenseReportSpec = ReportSpec(
  id: 'expense',
  title: 'Expense',
  category: 'Expense',
  groupBy: ReportGroupBy.month,
  sort: ReportSort(columnKey: 'date'),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kExpenseCategoryFilterId,
      label: 'Category',
      value: null,
      hint: 'Every category',
    ),
  ],
  columns: [
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(key: 'number', label: 'No.', emphasise: true),
    ReportColumn(key: 'category', label: 'Category', flex: 2),
    ReportColumn(key: 'vendor', label: 'Vendor / Payee', flex: 3),
    ReportColumn(key: 'mode', label: 'Mode', wideOnly: true),
    ReportColumn(
      key: 'reference',
      label: 'Reference',
      wideOnly: true,
      optional: true,
    ),
    ReportColumn(key: 'net', label: 'Net expense', kind: ReportValueKind.money),
    ReportColumn(
      key: 'gst',
      label: 'GST',
      kind: ReportValueKind.money,
      wideOnly: true,
    ),
    ReportColumn(
      key: 'amount',
      label: 'Total',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
  ],
  footnote:
      'Every non-deleted business expense in the period, grouped by month. '
      'Other income is excluded. When an expense carries recoverable GST, Net '
      'expense is the cost after input tax credit — matching the Profit & Loss '
      'statement — while Total is the full amount paid.',
);

const ReportDefinition expenseReport = ReportDefinition(
  spec: expenseReportSpec,
  source: CallbackReportSource(
    sourceId: 'expense',
    query: expenseReportRows,
    options: expenseCategoryOptions,
  ),
);

Future<List<ReportRow>> expenseReportRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selectedCategory = selectedExpenseCategory(filters);
  final query = db.select(db.expenses)
    ..where((e) => liveExpensesIn(window, firmId, db.expenses))
    ..orderBy([
      (e) => OrderingTerm.asc(e.date),
      (e) => OrderingTerm.asc(e.number),
    ]);

  final rows = <ReportRow>[];
  for (final exp in await query.get()) {
    final categoryLabel = expenseCategoryLabel(exp.category);
    if (selectedCategory != null && categoryLabel != selectedCategory) {
      continue;
    }
    final total = dec(exp.amount);
    final gst = dec(exp.gstAmount);
    final net = exp.itcEligible && gst > Decimal.zero && gst <= total
        ? total - gst
        : total;
    rows.add(
      ReportRow({
        'date': exp.date,
        'number': exp.number,
        'category': categoryLabel,
        'vendor': (exp.vendorName ?? '').trim().isEmpty
            ? '—'
            : exp.vendorName!.trim(),
        'mode': paymentModeLabel(exp.mode),
        'reference': (exp.reference ?? '').trim(),
        'net': net,
        'gst': gst,
        'amount': total,
      }, label: exp.number),
    );
  }
  return rows;
}
