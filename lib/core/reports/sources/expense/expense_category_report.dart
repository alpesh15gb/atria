import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/utils/money.dart';
import 'package:decimal/decimal.dart';

import '../transaction/transaction_common.dart';
import 'expense_common.dart';

/// **Expense Category Report** — spending aggregated by category.
///
/// One row per expense category that had spending in the period, sorted by
/// total spending descending, with each category's share of total expenditure.
const ReportSpec expenseCategoryReportSpec = ReportSpec(
  id: 'expense_category',
  title: 'Expense Category Report',
  category: 'Expense',
  sort: ReportSort(columnKey: 'amount', descending: true),
  columns: [
    ReportColumn(key: 'category', label: 'Category', flex: 3, emphasise: true),
    ReportColumn(key: 'count', label: 'Entries', kind: ReportValueKind.count),
    ReportColumn(
      key: 'net',
      label: 'Net expense',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(
      key: 'gst',
      label: 'GST',
      kind: ReportValueKind.money,
      wideOnly: true,
    ),
    ReportColumn(
      key: 'amount',
      label: 'Total spent',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
    ReportColumn(key: 'share', label: 'Share', kind: ReportValueKind.percent),
  ],
  footnote:
      'Spending grouped by expense category for the period. Net expense '
      'excludes recoverable GST so the total matches the operating expenses '
      'section of the Profit & Loss statement.',
);

const ReportDefinition expenseCategoryReport = ReportDefinition(
  spec: expenseCategoryReportSpec,
  source: CallbackReportSource(
    sourceId: 'expense_category',
    query: expenseCategoryReportRows,
  ),
);

class _CategoryAccum {
  int count = 0;
  Decimal net = Decimal.zero;
  Decimal gst = Decimal.zero;
  Decimal total = Decimal.zero;
}

Future<List<ReportRow>> expenseCategoryReportRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final query = db.select(db.expenses)
    ..where((e) => liveExpensesIn(window, firmId, db.expenses));

  final buckets = <String, _CategoryAccum>{};
  var grandTotal = Decimal.zero;

  for (final exp in await query.get()) {
    final label = expenseCategoryLabel(exp.category);
    final total = dec(exp.amount);
    final gst = dec(exp.gstAmount);
    final net = exp.itcEligible && gst > Decimal.zero && gst <= total
        ? total - gst
        : total;

    final acc = buckets.putIfAbsent(label, _CategoryAccum.new);
    acc.count += 1;
    acc.net += net;
    acc.gst += gst;
    acc.total += total;
    grandTotal += total;
  }

  if (buckets.isEmpty) return const [];

  final rows = <ReportRow>[];
  for (final entry in buckets.entries) {
    final acc = entry.value;
    final share = grandTotal == Decimal.zero
        ? Decimal.zero
        : Money.round2(
            (acc.total * Decimal.fromInt(100) / grandTotal).toDecimal(
              scaleOnInfinitePrecision: 6,
            ),
          );
    rows.add(
      ReportRow({
        'category': entry.key,
        'count': Decimal.fromInt(acc.count),
        'net': acc.net,
        'gst': acc.gst,
        'amount': acc.total,
        'share': share,
      }, label: entry.key),
    );
  }
  return rows;
}
