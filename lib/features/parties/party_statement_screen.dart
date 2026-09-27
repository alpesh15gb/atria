import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/database/repositories/report_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/status_chip.dart';

enum _DateRange { thisMonth, thisFY, allTime }

class PartyStatementScreen extends ConsumerStatefulWidget {
  const PartyStatementScreen({super.key, required this.partyId});

  final String partyId;

  @override
  ConsumerState<PartyStatementScreen> createState() =>
      _PartyStatementScreenState();
}

class _PartyStatementScreenState extends ConsumerState<PartyStatementScreen> {
  _DateRange _range = _DateRange.thisMonth;

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(reportRepositoryProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back',
          onPressed: () => context.pop(),
        ),
        title: const Text('Statement'),
        actions: [
          IconButton(
            tooltip: 'Share statement',
            onPressed: repository == null
                ? null
                : () => _share(repository),
            icon: const Icon(Icons.share_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.isCompact ? double.infinity : 900,
                ),
                child: repository == null
                    ? _disabledState
                    : _body(repository),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget get _disabledState => const EmptyState(
        icon: Icons.storefront_outlined,
        title: 'No business open',
        message: 'Set up a firm in Settings to view statements.',
      );

  DateTime? get _from {
    final now = DateTime.now();
    switch (_range) {
      case _DateRange.thisMonth:
        return DateTime(now.year, now.month, 1);
      case _DateRange.thisFY:
        return now.month >= 4 ? DateTime(now.year, 4, 1) : DateTime(now.year - 1, 4, 1);
      case _DateRange.allTime:
        return null;
    }
  }

  DateTime? get _to => _range == _DateRange.allTime ? null : DateTime.now();

  Widget _body(ReportRepository repository) {
    return Column(
      children: [
        _rangePills,
        const SizedBox(height: 12),
        Expanded(
          child: FutureBuilder<PartyStatement>(
            key: ValueKey('${widget.partyId}|${_range.name}'),
            future: repository.partyStatement(
              partyId: widget.partyId,
              from: _from,
              to: _to,
            ),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not load statement',
                  message: '${snapshot.error}',
                );
              }
              final statement = snapshot.data;
              if (statement == null) {
                return const EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'No statement',
                );
              }
              return _ledger(statement);
            },
          ),
        ),
      ],
    );
  }

  Widget get _rangePills => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              for (final range in _DateRange.values)
                Expanded(
                  child: _pill(range),
                ),
            ],
          ),
        ),
      );

  Widget _pill(_DateRange range) {
    final selected = _range == range;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => setState(() => _range = range),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: selected ? scheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md - 4),
          border: selected ? Border.all(color: scheme.outline, width: 0.9) : null,
        ),
        alignment: Alignment.center,
        child: Text(
          switch (range) {
            _DateRange.thisMonth => 'This Month',
            _DateRange.thisFY => 'This FY',
            _DateRange.allTime => 'All Time',
          },
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _ledger(PartyStatement statement) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _headerCard(statement)),
        if (statement.lines.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'No transactions',
              message: _range == _DateRange.allTime
                  ? 'There are no entries in ${statement.partyName}’s ledger yet.'
                  : 'No transactions in this period. Try “All Time” to see the '
                      'full ledger.',
            ),
          )
        else ...[
          SliverToBoxAdapter(child: _columnHeaders()),
          SliverList.separated(
            itemCount: statement.lines.length,
            separatorBuilder: (_, _) => Divider(
              color: Theme.of(context).colorScheme.outline,
              height: 1,
              indent: 12,
              endIndent: 12,
            ),
            itemBuilder: (context, index) =>
                _LedgerRow(line: statement.lines[index]),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ],
    );
  }

  Widget _columnHeaders() {
    final text = Theme.of(context).textTheme;
    final style = text.labelSmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      letterSpacing: 0.4,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text('DATE & PARTICULARS', style: style)),
          Expanded(flex: 3, child: Text('DEBIT', style: style, textAlign: TextAlign.right)),
          Expanded(flex: 3, child: Text('CREDIT', style: style, textAlign: TextAlign.right)),
          Expanded(flex: 4, child: Text('BALANCE', style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _headerCard(PartyStatement statement) {
    final colors = atriaColors(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final hasLines = statement.lines.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: AtriaCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.person_rounded,
                    color: scheme.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statement.partyName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasLines
                            ? '${statement.lines.length} entries • ${_rangeLabel()}'
                            : 'No entries in this period',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Share statement',
                  onPressed: () => _share(
                    ref.read(reportRepositoryProvider)!,
                    statement,
                  ),
                  icon: const Icon(Icons.share_rounded),
                ),
              ],
            ),
            const SizedBox(height: 16),
            IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(
                    child: _balanceCell(
                      label: 'Opening balance',
                      amount: statement.opening,
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    color: scheme.outline,
                    indent: 4,
                    endIndent: 4,
                  ),
                  Expanded(
                    child: _balanceCell(
                      label: 'Closing balance',
                      amount: statement.closing,
                      emphasize: true,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  statement.closing > Decimal.zero
                      ? Icons.trending_up_rounded
                      : statement.closing < Decimal.zero
                          ? Icons.trending_down_rounded
                          : Icons.trending_flat_rounded,
                  size: 16,
                  color: statement.closing > Decimal.zero
                      ? colors.positive
                      : statement.closing < Decimal.zero
                          ? colors.negative
                          : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    statement.closing > Decimal.zero
                        ? '${statement.partyName} owes you'
                        : statement.closing < Decimal.zero
                            ? 'You owe ${statement.partyName}'
                            : 'Account settled',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _balanceCell({
    required String label,
    required Decimal amount,
    bool emphasize = false,
  }) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: text.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        MoneyText(
          amount,
          signMode: MoneySignMode.auto,
          style: (emphasize ? text.titleLarge : text.titleMedium)?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
      ],
    );
  }

  String _rangeLabel() {
    switch (_range) {
      case _DateRange.thisMonth:
        return Formatters.monthYear(DateTime.now());
      case _DateRange.thisFY:
        final from = _from;
        return from == null ? 'this FY' : 'FY ${from.year}';
      case _DateRange.allTime:
        return 'all time';
    }
  }

  Future<void> _share(
    ReportRepository repository, [
    PartyStatement? cached,
  ]) async {
    final statement = cached ??
        await repository.partyStatement(
          partyId: widget.partyId,
          from: _from,
          to: _to,
        );
    final buffer = StringBuffer()
      ..writeln('Statement of Account')
      ..writeln('Party: ${statement.partyName}')
      ..writeln('Period: ${_shareRangeLabel()}')
      ..writeln('Opening balance: ${Formatters.money(statement.opening)}')
      ..writeln();
    if (statement.lines.isEmpty) {
      buffer.writeln('No transactions in this period.');
    } else {
      buffer
        ..writeln(
          'Date        Particulars                          Debit        Credit       Balance',
        )
        ..writeln('-' * 90);
      for (final line in statement.lines) {
        buffer.writeln(
          '${Formatters.isoDate(line.date).padRight(11)} '
          '${line.particulars.padRight(35).substring(0, line.particulars.length > 35 ? 35 : line.particulars.length)} '
          '${_padMoney(line.debit)} '
          '${_padMoney(line.credit)} '
          '${_padMoney(line.balance)}',
        );
      }
    }
    buffer
      ..writeln()
      ..writeln('Closing balance: ${Formatters.money(statement.closing)}')
      ..writeln('— Shared from Atria');
    await Share.share(buffer.toString());
  }

  String _shareRangeLabel() {
    switch (_range) {
      case _DateRange.thisMonth:
        return Formatters.monthYear(DateTime.now());
      case _DateRange.thisFY:
        final from = _from;
        return from == null
            ? 'all time'
            : 'FY ${from.year}-${(from.year + 1) % 100}';
      case _DateRange.allTime:
        return 'all time';
    }
  }

  String _padMoney(Decimal value) {
    final body = Formatters.money(value, showSymbol: false);
    return body.length <= 13 ? body.padLeft(13) : body;
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.line});

  final LedgerLine line;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = atriaColors(context);
    final negative = line.balance < Decimal.zero;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  Formatters.date(line.date),
                  style: text.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  line.particulars,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (line.reference.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  StatusChip(
                    label: line.reference,
                    kind: ChipKind.neutral,
                    size: ChipSize.small,
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: _amountCell(context, line.debit, colors.negative),
          ),
          Expanded(
            flex: 3,
            child: _amountCell(context, line.credit, colors.positive),
          ),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                MoneyText(
                  line.balance,
                  signMode: MoneySignMode.auto,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  negative ? 'Payable' : 'Receivable',
                  style: text.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: negative ? colors.negative : colors.positive,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _amountCell(
    BuildContext context,
    Decimal value,
    Color color,
  ) {
    if (value == Decimal.zero) {
      return const SizedBox();
    }
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        );
    return Align(
      alignment: Alignment.centerRight,
      child: MoneyText(
        value,
        compact: true,
        style: style,
      ),
    );
  }
}
