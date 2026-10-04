import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/theme/app_sizes.dart';
import 'package:atria/shared/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

/// **Trial Balance**, drawn as the debit/credit table it is.
///
/// Five columns do not fit a phone, so it is a real table with a horizontally
/// scrollable body and a pinned header rather than a card list. A trial balance
/// read one card at a time is not a trial balance — the reader's whole task is
/// scanning a column against another and spotting where one runs out.
///
/// **The figures are the source's, not recomputed here.** `debit` and `credit`
/// arrive as magnitudes and `closing` arrives signed; the brackets below are
/// presentation of a sign the source already decided. Recomputing in the widget
/// would mean the screen could disagree with the export, and the export is what
/// the CA files.
Widget? buildTrialBalance(BuildContext context, ReportResult result) {
  if (result.rows.isEmpty) return null;

  final opening = result.spec.columns.firstWhere((c) => c.key == 'opening');
  final debit = result.spec.columns.firstWhere((c) => c.key == 'debit');
  final credit = result.spec.columns.firstWhere((c) => c.key == 'credit');
  final closing = result.spec.columns.firstWhere((c) => c.key == 'closing');

  var totalOpening = Decimal.zero;
  var totalDebit = Decimal.zero;
  var totalCredit = Decimal.zero;
  var totalClosing = Decimal.zero;
  for (final row in result.rows) {
    totalOpening += row.number(opening);
    totalDebit += row.number(debit);
    totalCredit += row.number(credit);
    totalClosing += row.number(closing);
  }

  return Column(
    children: [
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: SizedBox(
              // A fixed width, not an intrinsic one and not a min-width
              // constraint. The columns have to stay in proportion to each
              // other, so letting the longest account name set the table's width
              // pushes the money columns off a narrow screen; and a
              // `ConstrainedBox(minWidth:)` inside a horizontal scroll view
              // leaves `maxWidth` infinite, which a `Column` with stretched
              // cross-axis alignment cannot lay out against — it throws
              // "BoxConstraints forces an infinite width" on every trial
              // balance rather than merely looking wrong.
              width: 620,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                    opening: opening,
                    debit: debit,
                    credit: credit,
                    closing: closing,
                  ),
                  for (final row in result.rows)
                    _TrialRow(
                      code: '${row.cells['code'] ?? ''}',
                      account: '${row.cells['account'] ?? ''}',
                      opening: row.number(opening),
                      debit: row.number(debit),
                      credit: row.number(credit),
                      closing: row.number(closing),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      // Pinned outside the scroll view, because the two totals are the whole
      // point of the document and a total the reader has to scroll back up to
      // find is a total they will not check.
      _Totals(
        opening: totalOpening,
        debit: totalDebit,
        credit: totalCredit,
        closing: totalClosing,
        balanced: totalDebit == totalCredit,
      ),
    ],
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.opening,
    required this.debit,
    required this.credit,
    required this.closing,
  });

  final ReportColumn opening;
  final ReportColumn debit;
  final ReportColumn credit;
  final ReportColumn closing;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xxs,
      ),
      child: Row(
        children: [
          _cell(context, 'Account', style, flex: 3),
          _cell(context, opening.label, style),
          _cell(context, debit.label, style),
          _cell(context, credit.label, style),
          _cell(context, closing.label, style),
        ],
      ),
    );
  }

  static Widget _cell(
    BuildContext context,
    String label,
    TextStyle? style, {
    int flex = 2,
  }) => Expanded(
    flex: flex,
    child: Text(label, textAlign: TextAlign.right, style: style),
  );
}

class _TrialRow extends StatelessWidget {
  const _TrialRow({
    required this.code,
    required this.account,
    required this.opening,
    required this.debit,
    required this.credit,
    required this.closing,
  });

  final String code;
  final String account;
  final Decimal opening;
  final Decimal debit;
  final Decimal credit;
  final Decimal closing;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.black12, width: 0.4)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              // The code is the ledger's own handle on the account and is what a
              // reader cross-references against, so it leads rather than sitting
              // in a column of its own — on a phone there is no room for both.
              code.isEmpty ? account : '$code  $account',
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _money(context, opening, style),
          _money(context, debit, style),
          _money(context, credit, style),
          // A credit closing balance in brackets. The sign convention stays the
          // source's; brackets are how a bookkeeper already reads it, and a
          // minus sign next to a column headed "Closing" invites someone to
          // subtract it a second time.
          _money(
            context,
            closing,
            style?.copyWith(
              fontWeight: closing < Decimal.zero ? FontWeight.w700 : null,
            ),
            brackets: closing < Decimal.zero,
          ),
        ],
      ),
    );
  }

  static Widget _money(
    BuildContext context,
    Decimal amount,
    TextStyle? style, {
    bool brackets = false,
  }) => Expanded(
    flex: 2,
    child: MoneyText(
      brackets ? -amount : amount,
      style: style,
      textAlign: TextAlign.right,
      // Colourising a closing balance would paint every credit balance red,
      // and red means "money out" everywhere else in this app. A credit
      // balance is not a loss, so the column stays neutral.
      colorize: false,
    ),
  );
}

class _Totals extends StatelessWidget {
  const _Totals({
    required this.opening,
    required this.debit,
    required this.credit,
    required this.closing,
    required this.balanced,
  });

  final Decimal opening;
  final Decimal debit;
  final Decimal credit;
  final Decimal closing;
  final bool balanced;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: balanced ? null : scheme.error,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              balanced ? 'Balanced' : 'Does NOT balance',
              style: style?.copyWith(
                color: balanced ? scheme.primary : scheme.error,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: MoneyText(
              opening,
              style: style,
              colorize: false,
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 2,
            child: MoneyText(
              debit,
              style: style,
              colorize: false,
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 2,
            child: MoneyText(
              credit,
              style: style,
              colorize: false,
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 2,
            child: MoneyText(
              closing,
              style: style,
              colorize: false,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
