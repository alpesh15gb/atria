import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import '../transaction/transaction_common.dart';

/// **Loan Statement** — money borrowed or lent, and the repayments and
/// interest against it.
///
/// **`principalAmount` and `amount` are kept separate on purpose.** Interest
/// does not reduce principal, so an interest-only repayment leaves principal
/// at zero — which is what separates "paying off the loan" from "paying this
/// month's interest".
///
/// **The running balance tracks outstanding principal**, replayed from the
/// loan's inception so a period starting mid-loan opens at the true principal
/// outstanding on that date. If a loan has no recorded disbursement row, its
/// `loans.principalAmount` is treated as the starting principal on
/// `loans.startDate`.
const ReportSpec loanStatementSpec = ReportSpec(
  id: 'loan_statement',
  title: 'Loan Statement',
  category: 'Loan',
  groupBy: ReportGroupBy.account,
  sort: ReportSort(columnKey: 'date'),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kLoanFilterId,
      label: 'Loan',
      value: null,
      hint: 'Every loan',
    ),
  ],
  columns: [
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(
      key: 'account',
      label: 'Loan / Lender',
      flex: 3,
      emphasise: true,
    ),
    ReportColumn(key: 'direction', label: 'Direction'),
    ReportColumn(key: 'kind', label: 'Transaction', flex: 2),
    ReportColumn(
      key: 'reference',
      label: 'Reference',
      wideOnly: true,
      optional: true,
    ),
    ReportColumn(
      key: 'principal',
      label: 'Principal',
      kind: ReportValueKind.money,
      flex: 2,
      colorize: true,
    ),
    ReportColumn(
      key: 'interest',
      label: 'Interest',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'amount',
      label: 'Total paid / received',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
    ReportColumn(
      key: 'balance',
      label: 'Outstanding principal',
      kind: ReportValueKind.running,
      flex: 2,
      emphasise: true,
    ),
  ],
  footnote:
      'Principal and interest are shown separately: interest paid does not '
      'reduce the outstanding principal, so an interest-only repayment leaves '
      'the principal balance unchanged. Outstanding principal is replayed from '
      'the start of each loan so the opening figure is accurate for any period.',
);

const String kLoanFilterId = 'loanId';

const ReportDefinition loanStatement = ReportDefinition(
  spec: loanStatementSpec,
  source: CallbackReportSource(
    sourceId: 'loan_statement',
    query: loanStatementRows,
    options: _loanOptions,
  ),
);

Future<List<ReportFilterOption<Object?>>> _loanOptions(
  AppDatabase db,
  String firmId,
  ReportSpec spec,
  String filterId,
) async {
  if (filterId != kLoanFilterId) return const [];
  final loans =
      await (db.select(db.loans)
            ..where((l) => l.firmId.equals(firmId) & l.isArchived.equals(false))
            ..orderBy([(l) => OrderingTerm.asc(l.startDate)]))
          .get();
  return [
    for (final loan in loans)
      ReportFilterOption<Object?>(
        value: loan.id,
        label: _loanDisplayName(loan),
      ),
  ];
}

String _loanDisplayName(LoanEntity loan) {
  final party = (loan.partyName ?? '').trim();
  final dir = loan.direction == 'lent' ? 'Lent' : 'Borrowed';
  if (party.isNotEmpty) return '$party ($dir)';
  return '$dir loan (${loan.id})';
}

String _kindLabel(String kind) => switch (kind) {
  'disbursement' => 'Disbursement',
  'repayment' => 'Repayment',
  'interest_charge' => 'Interest charge',
  'adjustment' => 'Adjustment',
  _ => kind,
};

bool _withinWindow(DateTime date, ReportWindow window) {
  if (window.from != null && date.isBefore(window.from!)) return false;
  if (window.to != null && date.isAfter(window.to!)) return false;
  return true;
}

Future<List<ReportRow>> loanStatementRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selectedLoanId = filters[kLoanFilterId]?.toString().trim();
  final hasSelection = selectedLoanId != null && selectedLoanId.isNotEmpty;

  final loansQuery = db.select(db.loans)
    ..where(
      (l) =>
          l.firmId.equals(firmId) &
          l.isArchived.equals(false) &
          (hasSelection ? l.id.equals(selectedLoanId) : const Constant(true)),
    )
    ..orderBy([
      (l) => OrderingTerm.asc(l.startDate),
      (l) => OrderingTerm.asc(l.id),
    ]);

  final loans = await loansQuery.get();
  if (loans.isEmpty) return const [];

  final loanIds = [for (final l in loans) l.id];
  final txns =
      await (db.select(db.loanTransactions)
            ..where((t) => t.firmId.equals(firmId) & t.loanId.isIn(loanIds))
            ..orderBy([
              (t) => OrderingTerm.asc(t.date),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  final txnsByLoan = <String, List<LoanTransactionEntity>>{};
  for (final t in txns) {
    (txnsByLoan[t.loanId] ??= <LoanTransactionEntity>[]).add(t);
  }

  final rows = <ReportRow>[];
  for (final loan in loans) {
    final label = _loanDisplayName(loan);
    final dirLabel = loan.direction == 'lent' ? 'Lent' : 'Borrowed';
    final loanTxns = txnsByLoan[loan.id] ?? const [];

    final hasDisbursementTxn = loanTxns.any((t) => t.kind == 'disbursement');
    var balance = Decimal.zero;

    // If no explicit disbursement transaction was recorded, the loan's
    // principalAmount on startDate is the initial advance.
    if (!hasDisbursementTxn && loan.principalAmount > 0) {
      final initialPrincipal = dec(loan.principalAmount);
      balance += initialPrincipal;
      if (_withinWindow(loan.startDate, window)) {
        rows.add(
          ReportRow({
            'date': loan.startDate,
            'account': label,
            'direction': dirLabel,
            'kind': 'Opening principal',
            'reference': (loan.notes ?? '').trim(),
            'principal': initialPrincipal,
            'interest': Decimal.zero,
            'amount': initialPrincipal,
            'balance': balance,
          }, label: label),
        );
      }
    }

    for (final t in loanTxns) {
      final p = dec(t.principalAmount);
      final intr = dec(t.interestAmount);
      final amt = dec(t.amount);

      // Principal delta: a disbursement increases outstanding principal;
      // a repayment reduces it; an interest_charge leaves principal untouched;
      // an adjustment moves principal by its signed principalAmount.
      final Decimal signedPrincipal;
      switch (t.kind) {
        case 'disbursement':
          signedPrincipal = p;
          balance += p;
        case 'repayment':
          signedPrincipal = -p;
          balance -= p;
        case 'interest_charge':
          signedPrincipal = Decimal.zero;
        default:
          signedPrincipal = p;
          balance += p;
      }

      if (_withinWindow(t.date, window)) {
        rows.add(
          ReportRow({
            'date': t.date,
            'account': label,
            'direction': dirLabel,
            'kind': _kindLabel(t.kind),
            'reference': (t.reference ?? '').trim(),
            'principal': signedPrincipal,
            'interest': intr,
            'amount': amt,
            'balance': balance,
          }, label: label),
        );
      }
    }
  }

  return rows;
}
