import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/report_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/services/statement_export.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/status_chip.dart';

enum _DateRange { thisMonth, thisFY, allTime }

/// Statement of Account — pick a party and a period, see the full debit /
/// credit ledger, download it as a formatted PDF or Excel workbook.
class StatementOfAccountScreen extends ConsumerStatefulWidget {
  const StatementOfAccountScreen({super.key, this.partyId});

  final String? partyId;

  @override
  ConsumerState<StatementOfAccountScreen> createState() =>
      _StatementOfAccountScreenState();
}

class _StatementOfAccountScreenState
    extends ConsumerState<StatementOfAccountScreen> {
  _DateRange _range = _DateRange.thisMonth;
  PartyEntity? _party;
  List<PartyEntity> _parties = const [];
  bool _loadingParties = true;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _loadParties();
  }

  Future<void> _loadParties() async {
    final repo = ref.read(partyRepositoryProvider);
    if (repo == null) {
      if (mounted) setState(() => _loadingParties = false);
      return;
    }
    final parties = await repo.all();
    if (!mounted) return;
    setState(() {
      _parties = parties;
      _loadingParties = false;
      if (widget.partyId != null) {
        _party = parties
            .where((p) => p.id == widget.partyId)
            .cast<PartyEntity?>()
            .firstWhere((p) => p != null, orElse: () => null);
      } else if (parties.isNotEmpty) {
        _party = parties.first;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(reportRepositoryProvider);
    final firm = ref.watch(activeFirmProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back',
          onPressed: () => context.pop(),
        ),
        title: const Text('Statement of Account'),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.isCompact ? double.infinity : 980,
                ),
                child: repository == null || firm == null
                    ? const EmptyState(
                        icon: Icons.storefront_outlined,
                        title: 'No business open',
                        message:
                            'Set up a business to view statements of account.',
                      )
                    : _body(repository, firm),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _body(ReportRepository repository, FirmEntity firm) {
    if (_loadingParties) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_parties.isEmpty) {
      return EmptyState(
        icon: Icons.people_outline_rounded,
        title: 'No parties yet',
        message: 'Add a customer or supplier first — their ledger appears '
            'here with PDF and Excel downloads.',
        actionLabel: 'Add Party',
        onAction: () => context.push('/parties/new'),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<PartyEntity>(
                  initialValue: _party,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Party',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                  items: [
                    for (final party in _parties)
                      DropdownMenuItem(
                        value: party,
                        child: Text(party.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) => setState(() => _party = value),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Row(
                    children: [
                      for (final range in _DateRange.values)
                        Expanded(child: _pill(range)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _exportBar(repository, firm),
        const SizedBox(height: 4),
        Expanded(child: _ledger(repository)),
      ],
    );
  }

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
          border:
              selected ? Border.all(color: scheme.outline, width: 0.9) : null,
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

  Widget _exportBar(ReportRepository repository, FirmEntity firm) {
    final scheme = Theme.of(context).colorScheme;
    final party = _party;
    final enabled = party != null && !_exporting;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(Icons.download_rounded,
              size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            'Download',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonalIcon(
            onPressed: enabled
                ? () => _download(repository, firm, asExcel: false)
                : null,
            icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
            label: const Text('PDF'),
          ),
          const SizedBox(width: 10),
          FilledButton.tonalIcon(
            onPressed: enabled
                ? () => _download(repository, firm, asExcel: true)
                : null,
            icon: const Icon(Icons.grid_on_rounded, size: 18),
            label: const Text('Excel'),
          ),
          if (_exporting) ...[
            const SizedBox(width: 12),
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _download(
    ReportRepository repository,
    FirmEntity firm, {
    required bool asExcel,
  }) async {
    final party = _party;
    if (party == null || _exporting) return;
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final statement = await repository.partyStatement(
        partyId: party.id,
        from: _from,
        to: _to,
      );
      final path = asExcel
          ? await StatementExport.exportExcel(
              statement: statement, firm: firm, from: _from, to: _to)
          : await StatementExport.exportPdf(
              statement: statement, firm: firm, from: _from, to: _to);
      messenger?.showSnackBar(SnackBar(
        content: Text(
            '${asExcel ? 'Excel' : 'PDF'} saved to Documents\\atria\\statements'),
      ));
      await OpenFilex.open(path);
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not export: $e')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  DateTime? get _from {
    final now = DateTime.now();
    switch (_range) {
      case _DateRange.thisMonth:
        return DateTime(now.year, now.month, 1);
      case _DateRange.thisFY:
        return now.month >= 4
            ? DateTime(now.year, 4, 1)
            : DateTime(now.year - 1, 4, 1);
      case _DateRange.allTime:
        return null;
    }
  }

  DateTime? get _to => _range == _DateRange.allTime ? null : DateTime.now();

  Widget _ledger(ReportRepository repository) {
    final party = _party;
    if (party == null) return const SizedBox.shrink();
    return FutureBuilder<PartyStatement>(
      key: ValueKey('${party.id}|${_range.name}'),
      future: repository.partyStatement(
        partyId: party.id,
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
        if (statement == null || statement.lines.isEmpty) {
          return const EmptyState(
            icon: Icons.receipt_long_outlined,
            title: 'No transactions',
            message:
                'No entries for this party in the selected period. Try “All '
                'Time” to see the full ledger.',
          );
        }
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _headerCard(statement)),
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
        );
      },
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
          Expanded(
              flex: 3,
              child:
                  Text('DEBIT', style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 3,
              child:
                  Text('CREDIT', style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 4,
              child:
                  Text('BALANCE', style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _headerCard(PartyStatement statement) {
    final colors = atriaColors(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: AtriaCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(
                    child: _balanceCell(
                        label: 'Opening balance', amount: statement.opening),
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
                        emphasize: true),
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
        const SizedBox(height: 2),
        MoneyText(
          amount,
          signMode: MoneySignMode.auto,
          style: text.titleMedium?.copyWith(
            fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    );
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
                  style:
                      text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
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
