import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import 'transaction_common.dart';

/// **Balance Sheet** — what the business owns and owes, as at the window's end.
///
/// `layout: document` because the three sections (assets, liabilities, equity)
/// are the structure. In a grid they are three arbitrary row labels and the one
/// equation the sheet exists to prove — assets = liabilities + equity — is
/// nowhere on the page.
///
/// **The window's end, not its middle.** A balance sheet is a photograph, so
/// `from` is ignored and only `asOf` is used. A "Balance Sheet for this
/// quarter" that showed the quarter's *end* is right; one that showed the start
/// would be a different document under the same name.
///
/// **Profit to date is inside equity, and it has to be.** `totalEquity` is the
/// capital accounts *plus* the year's profit, because profit that has not been
/// drawn out belongs to the owner. Omitting it is the classic balance-sheet
/// error and it is why this report folds `netProfit` into the equity section
/// rather than printing it as a footnote.
const ReportSpec balanceSheetSpec = ReportSpec(
  id: 'balance_sheet',
  title: 'Balance Sheet',
  category: 'Transaction',
  layout: ReportLayout.document,
  columns: [
    ReportColumn(key: 'section', label: 'Section', wideOnly: true),
    ReportColumn(key: 'group', label: 'Group', flex: 2, wideOnly: true),
    ReportColumn(key: 'account', label: 'Account', emphasise: true, flex: 3),
    ReportColumn(key: 'code', label: 'Code', wideOnly: true),
    ReportColumn(
      key: 'amount',
      label: 'Amount',
      kind: ReportValueKind.money,
      flex: 2,
    ),
  ],
  footnote:
      'As at the last day of the period. Liabilities and capital are shown '
      'as positive figures. Profit to date is the ledger\'s cumulative profit, '
      'in which a purchase is expensed when it is bought rather than held as a '
      'stock asset — so a month of buying ahead of selling shows a loss here '
      'while Bill Wise Profit shows a margin. The sheet still balances either '
      'way.',
);

const ReportDefinition balanceSheet = ReportDefinition(
  spec: balanceSheetSpec,
  source: CallbackReportSource(
    sourceId: 'balance_sheet',
    query: balanceSheetRows,
    notes: _balanceSheetNotes,
  ),
);

Future<List<ReportRow>> balanceSheetRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final sheet = await db
      .ledgerRepositoryFor(firmId)
      .balanceSheet(asOf: window.queryTo);

  final rows = <ReportRow>[
    for (final group in sheet.assets) ..._rowsFor('Assets', group, flip: false),
    for (final group in sheet.liabilities)
      ..._rowsFor('Liabilities', group, flip: true),
    for (final group in sheet.equity) ..._rowsFor('Equity', group, flip: true),
  ];
  // The period's profit is an equity account whether or not anyone has booked
  // it anywhere, so it is a row like any other and the section total it joins
  // is what makes assets equal liabilities plus equity.
  //
  // Skipped when it is exactly nil: a firm that has done nothing prints
  // "Profit to date 0.00" as though it were a result, and a sheet of one
  // invented row is not an empty sheet — it reads as a business with no money
  // and no stock rather than a business with nothing to report.
  if (sheet.netProfit != 0) {
    rows.add(
      ReportRow({
        'section': 'Equity',
        'group': 'Profit for the period',
        'account': sheet.netProfit > 0 ? 'Profit to date' : 'Loss to date',
        'code': '',
        'amount': dec(sheet.netProfit),
      }, label: sheet.netProfit > 0 ? 'Profit to date' : 'Loss to date'),
    );
  }
  return rows;
}

/// One row per account in [group].
///
/// [flip] negates `closing` for the liability and equity sections. The
/// repository signs every balance the same way — positive is a debit — so a
/// creditor prints as a negative figure, and a section of negative figures
/// added together is a section whose total is the wrong way round. The
/// BalanceSheetGroup.total getter applies the same flip for the same reason;
/// doing it here is what makes **this** report's own section totals foot.
List<ReportRow> _rowsFor(
  String section,
  BalanceSheetGroup group, {
  required bool flip,
}) {
  return [
    for (final line in group.accounts)
      ReportRow({
        'section': section,
        'group': group.title,
        'account': line.account.name,
        'code': line.account.code,
        'amount': flip ? -dec(line.closing) : dec(line.closing),
      }, label: line.account.name),
  ];
}

/// Does the sheet balance, and is the profit figure signed the way it reads?
List<String> _balanceSheetNotes(ReportResult result) {
  var assets = Decimal.zero;
  var liabilities = Decimal.zero;
  var equity = Decimal.zero;
  for (final row in result.rows) {
    final amount = row.number(_amountColumn);
    switch (row.cells['section']) {
      case 'Assets':
        assets += amount;
      case 'Liabilities':
        liabilities += amount;
      case 'Equity':
        equity += amount;
    }
  }
  final difference = assets - liabilities - equity;
  if (difference == Decimal.zero) {
    return [
      'Assets equal liabilities plus equity. The books balance as at '
          '${result.window.spanLabel}.',
    ];
  }
  return [
    'The sheet does NOT balance. Assets exceed liabilities plus equity by '
        '${_plain(difference)}. Check the Trial Balance for the same date first '
        '— the difference is the same one.',
  ];
}

const ReportColumn _amountColumn = ReportColumn(
  key: 'amount',
  label: 'Amount',
  kind: ReportValueKind.money,
);

String _plain(Decimal value) => value.round(scale: 2).toStringAsFixed(2);
