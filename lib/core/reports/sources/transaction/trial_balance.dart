import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import 'transaction_common.dart';

/// **Trial Balance Report** — every account, its period movement and its
/// closing balance.
///
/// `layout: document` because the document's whole content is a **debit/credit
/// column pair**. Forcing it into the grid would mean an account with a credit
/// balance printing its own negative in a single "Amount" column, which is
/// legible and wrong: a trial balance is read by comparing the two column
/// totals, and a signed column cannot be added up.
///
/// **Dr and Cr are magnitudes, not signs.** `closing` stays signed — that is
/// the repository's convention and it is what a sorted ledger wants — but
/// `dr` and `cr` hold positive figures on their own side, which is the only
/// shape in which `Total Dr == Total Cr` means the books balance. Printing a
/// signed closing under a heading that says "Debit" is how a trial balance ends
/// up with totals that differ by twice the difference.
///
/// **`from` splits opening from movement, and the window drives it.** Opening
/// balances are as of the window's start, movements are inside it. A report that
/// showed cumulative-to-date figures under a heading that said "This Quarter"
/// would be the single most misread screen in the app.
const ReportSpec trialBalanceSpec = ReportSpec(
  id: 'trial_balance',
  title: 'Trial Balance Report',
  category: 'Transaction',
  layout: ReportLayout.document,
  columns: [
    ReportColumn(key: 'code', label: 'Code', wideOnly: true),
    ReportColumn(key: 'account', label: 'Account', emphasise: true, flex: 3),
    ReportColumn(key: 'opening', label: 'Opening', kind: ReportValueKind.money),
    ReportColumn(key: 'debit', label: 'Debit', kind: ReportValueKind.money),
    ReportColumn(key: 'credit', label: 'Credit', kind: ReportValueKind.money),
    ReportColumn(
      key: 'closing',
      label: 'Closing',
      kind: ReportValueKind.money,
      flex: 2,
    ),
  ],
  footnote:
      'Opening balances are as at the start of the period. Debit and '
      'Credit columns hold positive figures; a closing balance in brackets is a '
      'credit balance.',
);

const ReportDefinition trialBalance = ReportDefinition(
  spec: trialBalanceSpec,
  source: CallbackReportSource(
    sourceId: 'trial_balance',
    query: trialBalanceRows,
    notes: _trialBalanceNotes,
  ),
);

Future<List<ReportRow>> trialBalanceRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final trial = await db
      .ledgerRepositoryFor(firmId)
      .trialBalance(
        asOf: window.queryTo,
        from: window.isOpenEnded ? null : window.queryFrom,
      );

  return [
    for (final row in trial.rows)
      ReportRow({
        'code': row.account.code,
        'account': row.account.name,
        // Opening is signed the way the repository signs it: positive is a
        // debit balance. A credit opening reads negative, which is why the
        // document body draws it in brackets rather than as a separate pair.
        'opening': dec(row.opening),
        'debit': dec(row.debit),
        'credit': dec(row.credit),
        'closing': dec(row.closing),
      }, label: row.account.name),
  ];
}

/// Whether the books foot, and by how much if they do not.
///
/// This is the one report where the integrity banner is *not* the right answer
/// and a note is: `assertIntegrity` checks the rows against the row's own
/// totals, and a trial balance that does not balance has perfectly consistent
/// rows. The fault is in the ledger, not in this report's arithmetic — so it
/// belongs in words above the table where a CA reads it, and the closing
/// difference must still print.
List<String> _trialBalanceNotes(ReportResult result) {
  var totalDebit = Decimal.zero;
  var totalCredit = Decimal.zero;
  for (final row in result.rows) {
    totalDebit += row.number(_debitColumn);
    totalCredit += row.number(_creditColumn);
  }
  final difference = totalDebit - totalCredit;
  if (difference == Decimal.zero) {
    return ['The books balance: total debits equal total credits.'];
  }
  return [
    'The books do NOT balance. Debits exceed credits by ${_plain(difference)}. '
        'A cause worth checking first: a hand-keyed journal voucher whose two '
        'sides do not agree, or a document posted for a different amount than '
        'the one entered.',
  ];
}

const ReportColumn _debitColumn = ReportColumn(
  key: 'debit',
  label: 'Debit',
  kind: ReportValueKind.money,
);
const ReportColumn _creditColumn = ReportColumn(
  key: 'credit',
  label: 'Credit',
  kind: ReportValueKind.money,
);

String _plain(Decimal value) => value.round(scale: 2).toStringAsFixed(2);
