import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/repositories/ledger_repository.dart';
import '../../core/reports/window/report_window.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import 'ledger_report_builder.dart';
import '../../shared/widgets/atria_list_page.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';

/// The period the ledger reports are looking at.
///
/// A `StateProvider` rather than a widget's own state so the trial balance and
/// the balance sheet agree while the user moves between them: two reports that
/// quietly covered different periods would be worse than no report at all.
///
/// All Time by default — a `DateTimeRange?` used to stand in for it, with null
/// meaning "no bounds", which is now what [ReportWindow.allTime] says
/// explicitly.
final ledgerPeriodProvider = StateProvider<ReportWindow>(
  (ref) => const ReportWindow(
    preset: ReportWindowPreset.allTime,
    from: null,
    to: null,
  ),
);

DateTime ledgerFrom(ReportWindow window) => window.queryFrom;

DateTime ledgerAsOf(ReportWindow window) => window.queryTo;

/// Trial balance: every account with its opening, movements and closing
/// balance, and the two column totals that have to agree.
class TrialBalanceScreen extends ConsumerWidget {
  const TrialBalanceScreen({super.key});

  static const String routePath = '/ledger/trial-balance';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `trialBalance` seeds the chart itself, so the report works for a firm that
    // has none; the screen does not write anything on build.
    final repo = ref.watch(ledgerRepositoryProvider);
    final range = ref.watch(ledgerPeriodProvider);
    final from = range.from;
    final asOf = ledgerAsOf(range);

    return AtriaListPage(
      title: 'Trial balance',
      subtitle:
          'As of ${Formatters.date(asOf)}. Closing debits must equal '
          'closing credits.',
      actions: [
        AtriaHeaderIconAction(
          icon: PhosphorIconsRegular.books,
          tooltip: 'Balance sheet',
          onPressed: () => context.push('/ledger/balance-sheet'),
        ),
      ],
      toolbar: [
        LedgerPeriodSelector(
          window: range,
          onChanged: (value) =>
              ref.read(ledgerPeriodProvider.notifier).state = value,
        ),
      ],
      body: repo == null
          ? const EmptyState(
              icon: PhosphorIconsRegular.bookOpen,
              title: 'No firm open',
              message: 'Open a business to see its ledger.',
            )
          : LedgerReportBuilder<TrialBalance>(
              repo: repo,
              query: () => repo.trialBalance(asOf: asOf, from: from),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return EmptyState(
                    icon: PhosphorIconsRegular.warningCircle,
                    title: 'Could not build the trial balance',
                    message: atriaErrorMessage(
                      snapshot.error,
                      retry: 'Try again.',
                    ),
                  );
                }
                final tb = snapshot.data;
                if (tb == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (tb.rows.isEmpty) {
                  return const EmptyState(
                    icon: PhosphorIconsRegular.scales,
                    title: 'Nothing posted yet',
                    message:
                        'Invoices, bills, payments, expenses and journal '
                        'vouchers all appear here once they exist.',
                  );
                }
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 600;
                    return ListView(
                      padding: const EdgeInsets.only(bottom: AppSpace.xxl),
                      children: [
                        _BalanceBanner(
                          balanced: tb.isBalanced,
                          difference: tb.difference,
                        ),
                        const SizedBox(height: AppSpace.md),
                        if (!narrow) _TrialHeader(from != null),
                        for (final row in tb.rows)
                          _TrialRow(
                            row: row,
                            compact: narrow,
                            showOpening: from != null,
                            onTap: () => context.push(
                              '/ledger/account/${row.account.id}',
                            ),
                          ),
                        _TrialTotals(
                          tb: tb,
                          showOpening: from != null,
                          compact: narrow,
                        ),
                      ],
                    );
                  },
                );
              },
            ),
    );
  }
}

/// Balance sheet: what the business owns, what it owes, and what is left for
/// the owner — with the profit the income and expense accounts have run up
/// folded into equity, so it balances without a year-end close.
class BalanceSheetScreen extends ConsumerWidget {
  const BalanceSheetScreen({super.key});

  static const String routePath = '/ledger/balance-sheet';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(ledgerRepositoryProvider);
    final range = ref.watch(ledgerPeriodProvider);
    final asOf = ledgerAsOf(range);

    return AtriaListPage(
      title: 'Balance sheet',
      subtitle: 'As of ${Formatters.date(asOf)}',
      actions: [
        AtriaHeaderIconAction(
          icon: PhosphorIconsRegular.scales,
          tooltip: 'Trial balance',
          onPressed: () => context.push('/ledger/trial-balance'),
        ),
      ],
      toolbar: [
        LedgerPeriodSelector(
          window: range,
          onChanged: (value) =>
              ref.read(ledgerPeriodProvider.notifier).state = value,
        ),
      ],
      body: repo == null
          ? const EmptyState(
              icon: PhosphorIconsRegular.bookOpen,
              title: 'No firm open',
              message: 'Open a business to see its balance sheet.',
            )
          : LedgerReportBuilder<BalanceSheet>(
              repo: repo,
              query: () => repo.balanceSheet(asOf: asOf),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return EmptyState(
                    icon: PhosphorIconsRegular.warningCircle,
                    title: 'Could not build the balance sheet',
                    message: atriaErrorMessage(
                      snapshot.error,
                      retry: 'Try again.',
                    ),
                  );
                }
                final sheet = snapshot.data;
                if (sheet == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (sheet.assets.isEmpty &&
                    sheet.liabilities.isEmpty &&
                    sheet.equity.isEmpty &&
                    sheet.netProfit == 0) {
                  return const EmptyState(
                    icon: PhosphorIconsRegular.books,
                    title: 'Nothing to report yet',
                    message:
                        'The balance sheet fills in as documents are '
                        'recorded and payments move.',
                  );
                }
                return ListView(
                  padding: const EdgeInsets.only(bottom: AppSpace.xxl),
                  children: [
                    _BalanceBanner(
                      balanced: sheet.isBalanced,
                      difference: sheet.difference,
                      balancedLabel: 'Assets equal liabilities plus equity',
                    ),
                    const SizedBox(height: AppSpace.md),
                    for (final group in sheet.assets)
                      _SheetGroup(group: group, title: 'Assets'),
                    _SheetTotal(
                      label: 'Total assets',
                      value: sheet.totalAssets,
                      emphasize: true,
                    ),
                    const SizedBox(height: AppSpace.lg),
                    for (final group in sheet.liabilities)
                      _SheetGroup(group: group, title: 'Liabilities'),
                    _SheetTotal(
                      label: 'Total liabilities',
                      value: sheet.totalLiabilities,
                      emphasize: true,
                    ),
                    const SizedBox(height: AppSpace.lg),
                    for (final group in sheet.equity)
                      _SheetGroup(group: group, title: 'Equity'),
                    _SheetTotal(
                      label: sheet.netProfit >= 0
                          ? 'Profit to date'
                          : 'Loss to date',
                      value: sheet.netProfit,
                      emphasize: false,
                    ),
                    _SheetTotal(
                      label: 'Total equity',
                      value: sheet.totalEquity,
                      emphasize: true,
                    ),
                  ],
                );
              },
            ),
    );
  }
}

/// One account's ledger, with a running balance.
class AccountLedgerScreen extends ConsumerWidget {
  const AccountLedgerScreen({super.key, required this.accountId});

  final String accountId;

  static String routeFor(String id) => '/ledger/account/$id';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(ledgerRepositoryProvider);
    final range = ref.watch(ledgerPeriodProvider);
    final from = range.from;
    final asOf = ledgerAsOf(range);

    return AtriaListPage(
      title: 'Account ledger',
      subtitle: 'Movements and the running balance',
      toolbar: [
        LedgerPeriodSelector(
          window: range,
          onChanged: (value) =>
              ref.read(ledgerPeriodProvider.notifier).state = value,
        ),
      ],
      body: repo == null
          ? const EmptyState(
              icon: PhosphorIconsRegular.bookOpen,
              title: 'No firm open',
              message: 'Open a business to see its ledger.',
            )
          : LedgerReportBuilder<AccountLedger>(
              repo: repo,
              query: () =>
                  repo.accountLedger(accountId, from: from, asOf: asOf),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return EmptyState(
                    icon: PhosphorIconsRegular.warningCircle,
                    title: 'Could not open the ledger',
                    message: atriaErrorMessage(
                      snapshot.error,
                      retry: 'Try again.',
                    ),
                  );
                }
                final ledger = snapshot.data;
                if (ledger == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final text = Theme.of(context).textTheme;
                final muted = Theme.of(context).colorScheme.onSurfaceVariant;
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 600;
                    return ListView(
                      padding: const EdgeInsets.only(bottom: AppSpace.xxl),
                      children: [
                        AtriaCard(
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${ledger.account.code}  '
                                      '${ledger.account.name}',
                                      style: text.titleMedium,
                                    ),
                                    Text(
                                      ledger.account.groupName.isEmpty
                                          ? ledger.account.type
                                          : ledger.account.groupName,
                                      style: text.bodySmall?.copyWith(
                                        color: muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('Closing', style: text.bodySmall),
                                  Text(
                                    '${Formatters.money(Money.of(ledger.closing))} '
                                    '${ledger.closing >= 0 ? 'Dr' : 'Cr'}',
                                    style: text.titleMedium,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpace.md),
                        if (!compact) _LedgerHeaderRow(),
                        _LedgerPlainRow(
                          label: 'Opening balance',
                          amount: ledger.opening,
                          emphasis: true,
                          compact: compact,
                        ),
                        if (ledger.rows.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: AppSpace.lg,
                            ),
                            child: Text(
                              'No movements in this period.',
                              style: text.bodyMedium?.copyWith(color: muted),
                            ),
                          ),
                        for (final row in ledger.rows)
                          _LedgerMovementRow(row: row, compact: compact),
                        _LedgerPlainRow(
                          label: 'Closing balance',
                          amount: ledger.closing,
                          emphasis: true,
                          compact: compact,
                        ),
                      ],
                    );
                  },
                );
              },
            ),
    );
  }
}

/// Period control shared by the three ledger reports.
///
/// Speaks [ReportWindow] like every other report screen, but keeps its own
/// three-button shape (All of time / This financial year / pick) rather than
/// the chip row — the ledger reports live in an [AtriaListPage] toolbar, where
/// a scrolling chip strip would cost more room than the three words it saves.
class LedgerPeriodSelector extends StatelessWidget {
  const LedgerPeriodSelector({
    super.key,
    required this.window,
    required this.onChanged,
  });

  final ReportWindow window;
  final ValueChanged<ReportWindow> onChanged;

  /// The window the "This financial year" button and the picker's default
  /// selection both offer.
  ///
  /// The Indian financial year, not the calendar year. `DateTime(now.year, 4, 1)`
  /// was the range before: on 15 Feb 2026 that is start 2026-04-01 / end
  /// 2026-02-15 — start AFTER end, so every movement failed
  /// `m.date.isBefore(from)`, both column totals printed ₹0.00 and only the
  /// carried-forward balances appeared, labelled as the period's activity.
  ReportWindow get _thisFy => ReportWindow.resolve(ReportWindowPreset.thisFY);

  static const ReportWindow _allTime = ReportWindow(
    preset: ReportWindowPreset.allTime,
    from: null,
    to: null,
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final allTime = window.isAllTime;

    return Row(
      children: [
        Expanded(
          child: Text(
            allTime ? 'All of time' : window.spanLabel,
            style: text.bodyMedium,
          ),
        ),
        if (!allTime)
          TextButton(
            onPressed: () => onChanged(_allTime),
            child: const Text('All of time'),
          ),
        TextButton(
          onPressed: () => onChanged(_thisFy),
          child: const Text('This financial year'),
        ),
        IconButton(
          tooltip: 'Pick a period',
          onPressed: () async {
            final fy = _thisFy;
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
              // Never a start after the end: the dialog refuses to confirm an
              // inverted range, so a stale `initialDateRange` left the user
              // unable to close it at all. The bounds here are day-stamped —
              // `ReportWindow.to` closes at 23:59:59 — so an end of "today at
              // 23:59" must not be handed to a picker that compares days.
              initialDateRange:
                  !allTime &&
                      window.from != null &&
                      window.to != null &&
                      !window.from!.isAfter(window.to!)
                  ? DateTimeRange(
                      start: window.from!,
                      end: DateTime(
                        window.to!.year,
                        window.to!.month,
                        window.to!.day,
                      ),
                    )
                  : DateTimeRange(
                      start: fy.from!,
                      end: DateTime(fy.to!.year, fy.to!.month, fy.to!.day),
                    ),
            );
            if (picked != null) {
              onChanged(
                ReportWindow.resolve(
                  ReportWindowPreset.custom,
                  customFrom: picked.start,
                  customTo: picked.end,
                ),
              );
            }
          },
          icon: const Icon(PhosphorIconsRegular.calendarBlank),
        ),
        if (allTime)
          Tooltip(
            message: 'Showing every period',
            child: Icon(PhosphorIconsRegular.info, size: 16, color: muted),
          ),
      ],
    );
  }
}

class _BalanceBanner extends StatelessWidget {
  const _BalanceBanner({
    required this.balanced,
    required this.difference,
    this.balancedLabel = 'Debits equal credits',
  });

  final bool balanced;
  final double difference;
  final String balancedLabel;

  @override
  Widget build(BuildContext context) {
    final colors = atriaColors(context);
    final text = Theme.of(context).textTheme;
    return AtriaCard(
      background: balanced ? colors.successSurface : colors.dangerSurface,
      showBorder: false,
      child: Row(
        children: [
          Icon(
            balanced
                ? PhosphorIconsRegular.checkCircle
                : PhosphorIconsRegular.warningCircle,
            color: balanced ? colors.onSuccessSurface : colors.onDangerSurface,
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(
              balanced
                  ? balancedLabel
                  : 'Out of balance by '
                        '${Formatters.money(Money.of(difference))}. Something was '
                        'posted on one side only.',
              style: text.bodyMedium?.copyWith(
                color: balanced
                    ? colors.onSuccessSurface
                    : colors.onDangerSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrialHeader extends StatelessWidget {
  const _TrialHeader(this.showOpening);

  final bool showOpening;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: muted, fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text('Account', style: style)),
          if (showOpening)
            Expanded(
              flex: 2,
              child: Text('Opening', style: style, textAlign: TextAlign.right),
            ),
          Expanded(
            flex: 2,
            child: Text('Debit', style: style, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 2,
            child: Text('Credit', style: style, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 2,
            child: Text('Closing', style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _TrialRow extends StatelessWidget {
  const _TrialRow({
    this.compact = false,
    required this.row,
    required this.showOpening,
    required this.onTap,
  });

  final LedgerAccountBalance row;
  final bool compact;
  final bool showOpening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final amountStyle = text.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final mutedAmount = amountStyle?.copyWith(color: muted);
    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: AtriaCard(
          child: InkWell(
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.account.name, style: text.titleSmall),
                Text(
                  '${row.account.code}  ${row.account.groupName}',
                  style: text.bodySmall?.copyWith(color: muted),
                ),
                const SizedBox(height: 8),
                if (showOpening)
                  _LedgerFigure(label: 'Opening', value: _signed(row.opening)),
                _LedgerFigure(label: 'Debit', value: _plain(row.debit)),
                _LedgerFigure(label: 'Credit', value: _plain(row.credit)),
                _LedgerFigure(
                  label: 'Closing',
                  value:
                      '${_plain(row.closing.abs())} ${row.isDr ? 'Dr' : 'Cr'}',
                ),
              ],
            ),
          ),
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The name column and the figures have to stay on one line
                  // each or the row loses all column alignment at phone width.
                  Text(
                    row.account.name,
                    style: text.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${row.account.code}'
                    '${row.account.groupName.isEmpty ? '' : '  ·  ${row.account.groupName}'}',
                    style: text.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            if (showOpening)
              Expanded(
                flex: 2,
                child: Text(
                  row.opening == 0 ? '' : _signed(row.opening),
                  style: mutedAmount,
                  textAlign: TextAlign.right,
                ),
              ),
            Expanded(
              flex: 2,
              child: Text(
                row.debit == 0 ? '' : _plain(row.debit),
                style: amountStyle,
                textAlign: TextAlign.right,
                // A money string has no break opportunities, and this column
                // is ~55dp at 360dp while "₹1,23,456.00" is ~90dp — without a
                // line clamp the figure paints across the Account column.
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                row.credit == 0 ? '' : _plain(row.credit),
                style: amountStyle,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                '${_plain(row.closing.abs())} ${row.isDr ? 'Dr' : 'Cr'}',
                style: amountStyle?.copyWith(fontWeight: FontWeight.w600),
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _plain(double value) => Formatters.money(Money.of(value));

  String _signed(double value) =>
      '${Formatters.money(Money.of(value.abs()))} ${value >= 0 ? 'Dr' : 'Cr'}';
}

class _TrialTotals extends StatelessWidget {
  const _TrialTotals({
    required this.tb,
    required this.showOpening,
    this.compact = false,
  });

  final bool compact;

  final TrialBalance tb;
  final bool showOpening;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final style = text.titleMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      fontWeight: FontWeight.w600,
    );
    if (compact) {
      return AtriaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Totals', style: style),
            if (showOpening)
              _LedgerFigure(
                label: 'Opening',
                value: Formatters.money(
                  Money.of(tb.totalOpeningDebit - tb.totalOpeningCredit),
                ),
              ),
            _LedgerFigure(
              label: 'Debit',
              value: Formatters.money(Money.of(tb.totalDebit)),
            ),
            _LedgerFigure(
              label: 'Credit',
              value: Formatters.money(Money.of(tb.totalCredit)),
            ),
            _LedgerFigure(
              label: 'Closing',
              value: Formatters.money(Money.of(tb.totalClosingDebit)),
            ),
          ],
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: AppSpace.sm),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          const Expanded(flex: 4, child: Text('Totals')),
          if (showOpening)
            Expanded(
              flex: 2,
              child: Text(
                Formatters.money(
                  Money.of(tb.totalOpeningDebit - tb.totalOpeningCredit),
                ),
                style: style,
                textAlign: TextAlign.right,
              ),
            ),
          Expanded(
            flex: 2,
            child: Text(
              Formatters.money(Money.of(tb.totalDebit)),
              style: style,
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              Formatters.money(Money.of(tb.totalCredit)),
              style: style,
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              Formatters.money(Money.of(tb.totalClosingDebit)),
              style: style,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetGroup extends StatelessWidget {
  const _SheetGroup({required this.group, required this.title});

  final BalanceSheetGroup group;
  final String title;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: group.title,
          padding: const EdgeInsets.only(top: AppSpace.md, bottom: AppSpace.xs),
        ),
        for (final account in group.accounts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${account.account.code}  ${account.account.name}',
                    style: text.bodyMedium,
                  ),
                ),
                Text(
                  '${Formatters.money(Money.of(account.closing.abs()))} '
                  '${account.isDr ? 'Dr' : 'Cr'}',
                  style: text.bodyMedium?.copyWith(
                    color: muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.xs, bottom: AppSpace.sm),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Total $title · ${group.title}',
                  style: text.bodySmall?.copyWith(color: muted),
                ),
              ),
              Text(
                Formatters.money(Money.of(group.total)),
                style: text.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SheetTotal extends StatelessWidget {
  const _SheetTotal({
    required this.label,
    required this.value,
    required this.emphasize,
  });

  final String label;
  final double value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: emphasize ? text.titleMedium : text.bodyMedium,
            ),
          ),
          Text(
            Formatters.money(Money.of(value)),
            style: (emphasize ? text.titleMedium : text.bodyMedium)?.copyWith(
              fontWeight: emphasize ? FontWeight.w600 : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _LedgerHeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: muted, fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text('Date', style: style)),
          Expanded(flex: 5, child: Text('Particulars', style: style)),
          Expanded(
            flex: 2,
            child: Text('Debit', style: style, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 2,
            child: Text('Credit', style: style, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 2,
            child: Text('Balance', style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

/// The "Opening balance" / "Closing balance" rows of the account ledger.
///
/// They must line up with the columns of [_LedgerHeaderRow] and
/// [_LedgerMovementRow] (Date 2, Particulars 5, Debit 2, Credit 2, Balance 2),
/// which is why the label spans Date+Particulars (7) and the figure occupies
/// the trailing Balance column (2) with the two amount columns left empty.
/// This row used to be a single 7/4 split, which pushed the figure ~25% of the
/// row to the right of the running-balance column — so the closing balance
/// printed under "Credit" and the two figures above it did not add up by eye.
class _LedgerPlainRow extends StatelessWidget {
  const _LedgerPlainRow({
    required this.label,
    required this.amount,
    required this.emphasis,
    this.compact = false,
  });

  final String label;
  final double amount;
  final bool emphasis;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final style = (emphasis ? text.titleMedium : text.bodyMedium)?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        child: _LedgerFigure(
          label: label,
          value:
              '${Formatters.money(Money.of(amount.abs()))} ${amount >= 0 ? 'Dr' : 'Cr'}',
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        children: [
          // Date (2) + Particulars (5).
          Expanded(flex: 7, child: Text(label, style: style)),
          // Debit (2) + Credit (2), intentionally blank.
          const Spacer(flex: 4),
          // Balance (2), right-aligned exactly like the running balance.
          Expanded(
            flex: 2,
            child: Text(
              '${Formatters.money(Money.of(amount.abs()))} '
              '${amount >= 0 ? 'Dr' : 'Cr'}',
              style: style,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _LedgerMovementRow extends StatelessWidget {
  const _LedgerMovementRow({required this.row, this.compact = false});

  final bool compact;

  final LedgerEntryRow row;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final balance = row.balance;
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        child: AtriaCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                Formatters.date(row.date),
                style: text.bodySmall?.copyWith(color: muted),
              ),
              Text(row.narration, style: text.bodyMedium),
              if (row.document != null)
                Text(row.document!, style: text.bodySmall),
              const SizedBox(height: AppSpace.sm),
              _LedgerFigure(
                label: 'Debit',
                value: Formatters.money(Money.of(row.debit)),
              ),
              _LedgerFigure(
                label: 'Credit',
                value: Formatters.money(Money.of(row.credit)),
              ),
              _LedgerFigure(
                label: 'Balance',
                value:
                    '${Formatters.money(Money.of(balance.abs()))} ${balance >= 0 ? 'Dr' : 'Cr'}',
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(Formatters.date(row.date), style: text.bodySmall),
          ),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.narration,
                  style: text.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (row.document != null)
                  Text(
                    row.document!,
                    style: text.bodySmall?.copyWith(color: muted),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              row.debit == 0 ? '' : Formatters.money(Money.of(row.debit)),
              style: text.bodyMedium,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              row.credit == 0 ? '' : Formatters.money(Money.of(row.credit)),
              style: text.bodyMedium,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${Formatters.money(Money.of(balance.abs()))} '
              '${balance >= 0 ? 'Dr' : 'Cr'}',
              style: text.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _LedgerFigure extends StatelessWidget {
  const _LedgerFigure({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
      ],
    ),
  );
}
