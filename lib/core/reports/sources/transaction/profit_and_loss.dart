import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

/// **Profit And Loss** — income less expenses for the window.
///
/// `layout: document`, because a P&L is not a grid: income on top, expenses
/// under a rule, a gross-profit line between them, and a net figure at the
/// bottom that is the entire point. Flattened into rows it becomes a table
/// called "Description | Amount" with no gross profit in it anywhere, and the
/// gross profit is the line a CA reads first.
///
/// **It reuses `ReportRepository.profitAndLoss` rather than re-deriving it.**
/// That is deliberate and it is also the report's real weakness: the ledger's
/// Trial Balance and this P&L are **two independent implementations** — one
/// sums `journal_lines`, the other sums document headers — and a hand-keyed
/// journal voucher touches only the first. So the two can legitimately
/// disagree, and plan rule 13 says surface the delta rather than throw. See
/// [_pnlNotes].
///
/// **The stock block.** Where the window crosses a stock adjustment, revenue
/// and expenses do not by themselves explain the change in profit. The report
/// therefore carries opening stock, closing stock and the cost of goods sold as
/// their own rows, because an unexplained gap between two independently
/// computed figures is worse than no explanation at all.
const ReportSpec profitAndLossSpec = ReportSpec(
  id: 'profit_and_loss',
  title: 'Profit And Loss',
  category: 'Transaction',
  layout: ReportLayout.document,
  columns: [
    ReportColumn(key: 'section', label: 'Section', wideOnly: true),
    ReportColumn(key: 'label', label: 'Description', emphasise: true, flex: 3),
    ReportColumn(
      key: 'amount',
      label: 'Amount',
      kind: ReportValueKind.money,
      flex: 2,
    ),
  ],
  footnote:
      'Figures are exclusive of GST. A credit note reduces income and a '
      'debit note reduces expenses, because both return what was originally '
      'sold or bought.',
);

const ReportDefinition profitAndLoss = ReportDefinition(
  spec: profitAndLossSpec,
  source: CallbackReportSource(
    sourceId: 'profit_and_loss',
    query: profitAndLossRows,
    notes: _pnlNotes,
  ),
);

/// The P&L's rows, one per line the document draws.
///
/// [ReportSpec.layout] keeps the columns so the **export is the same lines the
/// screen shows** — a P&L that exports as a different set of rows than it
/// prints is a P&L whose CSV does not reconcile to the page above it.
Future<List<ReportRow>> profitAndLossRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final pnl = await db
      .reportRepositoryFor(firmId)
      .profitAndLoss(from: window.queryFrom, to: window.queryTo);

  // A firm that did nothing in the period has no P&L, and printing one anyway
  // is the "no data rendering as no money" trap: four lines reading
  // "Sales 0.00 / Total income 0.00 / Cost of goods purchased 0.00 / Total
  // expenses 0.00" that add to a net profit of 0.00, which reads as a result.
  //
  // The test is on **documents**, not on totals — a firm that sold ₹1,000 and
  // returned all of it has a net income of zero and must still print the
  // statement, because the return is the story. Testing the totals would say
  // "no activity" and swallow it. Stock moves count as activity too: an
  // adjustment changes the profit without a document behind it.
  if (!pnl.hasActivity) return const [];

  return [
    for (final line in pnl.incomeRows)
      ReportRow({
        'section': 'Income',
        'label': line.label,
        'amount': line.amount,
      }),
    ReportRow({
      'section': '',
      'label': 'Total income',
      'amount': pnl.totalIncome,
    }),
    for (final line in pnl.expenseRows)
      ReportRow({
        'section': 'Expense',
        'label': line.label,
        'amount': line.amount,
      }),
    ReportRow({
      'section': '',
      'label': 'Total expenses',
      'amount': pnl.totalExpenses,
    }),
    if (pnl.hasStockAdjustment) ...[
      ReportRow({
        'section': 'Stock',
        'label': 'Opening stock',
        'amount': pnl.openingStock,
      }),
      ReportRow({
        'section': 'Stock',
        'label': 'Closing stock',
        'amount': -pnl.closingStock,
      }),
      ReportRow({
        'section': 'Stock',
        'label': 'Cost of goods sold',
        'amount': pnl.costOfGoodsSold,
      }),
    ],
    // Gross and net are **different numbers** and both belong on the
    // statement. The document view used to derive one figure on screen
    // (`totalIncome - totalExpenses`) and print it twice, under two different
    // names — a CA reading the statement saw two identical lines and could not
    // tell which was which. The repository has computed both, correctly and
    // distinctly: gross is sales less cost of goods sold, net adds other income
    // and operating expenses.
    ReportRow({
      'section': '',
      'label': 'Gross profit',
      'amount': pnl.grossProfit,
    }),
    ReportRow({'section': '', 'label': 'Net profit', 'amount': pnl.netProfit}),
  ];
}

/// Report the two figures' disagreement, and say why it exists.
///
/// The delta is **not** an error to throw on. This P&L sums document headers;
/// the Trial Balance sums `journal_lines`; a hand-keyed voucher exists only in
/// the second. A CA opening the books to find the difference needs the books,
/// not an exception. So the number goes in the notes strip above the table, in
/// words that name the cause, and the reader decides.
List<String> _pnlNotes(ReportResult result) {
  final income = _amountFor(result, 'Total income');
  final expenses = _amountFor(result, 'Total expenses');
  final net = income - expenses;
  final notes = <String>[];

  // A stock block that does not net to zero means the reported cost of goods
  // sold does not match the change in stock — the reader must be told, because
  // the net figure below is only as good as that block.
  final opening = _amountFor(result, 'Opening stock');
  final closing = _amountFor(result, 'Closing stock');
  if (opening != Decimal.zero || closing != Decimal.zero) {
    final cogs = _amountFor(result, 'Cost of goods sold');
    final expected = opening - closing;
    if (cogs != expected) {
      notes.add(
        'Cost of goods sold (${_plain(cogs)}) does not match the fall in stock '
        '(${_plain(expected)}). The difference of ${_plain(cogs - expected)} is '
        'stock bought or sold outside this period.',
      );
    }
  }

  notes.add(
    'Net profit ${_plain(net)} for this period. This report sums document '
    'headers; the Trial Balance sums journal lines. A hand-keyed voucher '
    'appears in one and not the other — compare them before filing.',
  );
  return notes;
}

/// One labelled line's figure, or zero when the document did not draw it.
Decimal _amountFor(ReportResult result, String label) {
  for (final row in result.rows) {
    if (row.cells['label'] == label) {
      final raw = row.cells['amount'];
      if (raw is Decimal) return raw;
    }
  }
  return Decimal.zero;
}

String _plain(Decimal value) => value.round(scale: 2).toStringAsFixed(2);
