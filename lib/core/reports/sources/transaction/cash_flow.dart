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

/// **Cash flow** — money in and out of cash and bank, month by month.
///
/// **The one report in this category that is entirely new.** Nothing in the app
/// produced one; the closest was a Cash-in-hand / Bank card on the dashboard,
/// which shows a balance and no history.
///
/// **Where it comes from: the cash and bank ledger accounts, not the payment
/// and expense tables.** That is the whole design decision, and it is what makes
/// the report agree with the Balance Sheet by construction. Payments and
/// expenses are the *causes* of cash movement, but a payment by cheque is not
/// cash movement until the cheque clears, and a journal voucher moves cash with
/// no payment or expense row at all. Reading the cash accounts sidesteps both —
/// including the bounced cheque, which `_book` already excludes at posting time
/// and which therefore never appears here. Re-deriving from the payment table
/// would have to re-implement that exclusion in a second place, which is how the
/// HIGH finding happened once already.
///
/// Cheques in hand are counted, because they are money the business has and has
/// not yet banked; a cheque that bounces simply never gets cleared.
///
/// **What it deliberately does not do.** It does not split into operating,
/// investing and financing. Those need the contra account on the far side of
/// every cash posting, and the app posts payments and expenses *directly* into
/// the ledger rather than as paired journal entries — so for most rows the
/// contra is not in the database at all, only a narration. Inventing a
/// classification from a narration string would produce a statement that looks
/// like the real thing and is not. The footnote says so on the page rather than
/// the screen quietly implying otherwise.
const ReportSpec cashFlowSpec = ReportSpec(
  id: 'cash_flow',
  title: 'Cash flow',
  category: 'Transaction',
  layout: ReportLayout.document,
  groupBy: ReportGroupBy.month,
  sort: ReportSort(columnKey: 'date'),
  columns: [
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(key: 'account', label: 'Account', wideOnly: true),
    ReportColumn(
      key: 'particulars',
      label: 'Particulars',
      emphasise: true,
      flex: 3,
    ),
    ReportColumn(key: 'reference', label: 'Reference', flex: 2, wideOnly: true),
    ReportColumn(key: 'inflow', label: 'Money in', kind: ReportValueKind.money),
    ReportColumn(
      key: 'outflow',
      label: 'Money out',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'closing',
      label: 'Balance',
      kind: ReportValueKind.running,
      flex: 2,
      colorize: true,
    ),
  ],
  footnote:
      'Cash, bank and cheques in hand. This is not split into operating, '
      'investing and financing: the app records payments and expenses straight '
      'to the ledger rather than as paired journal entries, so the account on '
      'the far side is not recorded and cannot be classified honestly.',
);

const ReportDefinition cashFlow = ReportDefinition(
  spec: cashFlowSpec,
  source: CallbackReportSource(sourceId: 'cash_flow', query: cashFlowRows),
);

/// The cash, bank and cheques-in-hand accounts a movement can sit in.
const List<String> _cashAccountCodes = [
  LedgerCodes.cash,
  LedgerCodes.bank,
  LedgerCodes.chequesInHand,
];

Future<List<ReportRow>> cashFlowRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final ledger = db.ledgerRepositoryFor(firmId);
  // The chart is seeded on demand, not by the migration, so a firm that has
  // never opened the ledger screen has no cash account at all. Every other
  // entry point here (`trialBalance`, `accountLedger`) calls `ensureChart`
  // itself; `byCode` does not, so this report would otherwise show an empty
  // cash flow for a firm that plainly has money in the bank.
  await ledger.ensureChart();

  // Opening is the sum across all three accounts, so the first row's balance is
  // the business's actual cash position at the start of the period rather than
  // whichever account happened to be read first.
  var opening = Decimal.zero;
  final movements = <_Movement>[];
  for (final code in _cashAccountCodes) {
    final account = await ledger.byCode(code);
    if (account == null) continue;
    final accountLedger = await ledger.accountLedger(
      account.id,
      from: window.isOpenEnded ? null : window.queryFrom,
      asOf: window.queryTo,
    );
    opening += dec(accountLedger.opening);
    for (final line in accountLedger.rows) {
      movements.add(
        _Movement(
          date: line.date,
          account: account.name,
          particulars: line.narration.isEmpty
              ? line.document ?? '—'
              : line.narration,
          reference: line.document ?? '',
          debit: dec(line.debit),
          credit: dec(line.credit),
        ),
      );
    }
  }
  if (movements.isEmpty) return const [];

  movements.sort((a, b) => a.date.compareTo(b.date));

  // The running balance is computed **here**, over the merged three-account
  // stream, rather than taken from any one account's `LedgerEntryRow.balance`
  // — each of those is that account's balance alone and would be three
  // different "balances" in one column.
  var running = opening;
  return [
    for (final m in movements)
      () {
        running += m.debit - m.credit;
        return ReportRow({
          'date': m.date,
          'account': m.account,
          'particulars': m.particulars,
          'reference': m.reference,
          'inflow': m.debit,
          'outflow': m.credit,
          'closing': running,
        }, label: m.particulars);
      }(),
  ];
}

/// One movement on a cash-like account.
class _Movement {
  const _Movement({
    required this.date,
    required this.account,
    required this.particulars,
    required this.reference,
    required this.debit,
    required this.credit,
  });

  final DateTime date;
  final String account;
  final String particulars;
  final String reference;
  final Decimal debit;
  final Decimal credit;
}
