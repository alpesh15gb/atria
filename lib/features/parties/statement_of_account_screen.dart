import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/party_repository.dart';
import '../../core/database/repositories/report_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/services/statement_export.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atria_field_icon.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/transaction_list.dart';

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

  /// The party whose ledger is shown. Null until the picker resolves one.
  PartyEntity? _party;

  /// The URL named a party that is not in the books (deleted, or a stale link).
  /// Reported explicitly — this used to resolve to null inside a 500-row list
  /// and render a blank white area with both downloads disabled.
  bool _partyMissing = false;

  /// True while a deep-linked party is being fetched by id. Set in
  /// [initState], where `widget` is readable.
  bool _resolving = false;

  bool _exporting = false;

  final TextEditingController _partySearchController = TextEditingController();
  String _partySearch = '';

  /// Cached so a rebuild does not resubscribe the drift watch; the list is a
  /// stream now, not a one-shot read.
  Stream<List<PartyEntity>>? _parties;
  PartyRepository? _partiesRepo;

  @override
  void initState() {
    super.initState();
    if (widget.partyId != null) {
      _resolving = true;
      _resolveDeepLinkedParty();
    }
  }

  @override
  void dispose() {
    _partySearchController.dispose();
    super.dispose();
  }

  /// Every live party, uncapped and watched.
  ///
  /// `watchAll` is unbounded by design; the old `repo.all()` took its default
  /// 500-row cap and never re-read, so parties past that were invisible and a
  /// party created elsewhere in the app never appeared here.
  Stream<List<PartyEntity>> _partiesStream(PartyRepository repo) {
    if (_parties == null || _partiesRepo != repo) {
      _partiesRepo = repo;
      _parties = repo.watchAll();
    }
    return _parties!;
  }

  /// Resolves `/statements?party=<id>`.
  ///
  /// By ID, not by scanning a list: having the id is the entire point, and the
  /// old lookup only found the party if it happened to sit inside the first 500
  /// rows of a name-ordered query.
  Future<void> _resolveDeepLinkedParty() async {
    final id = widget.partyId;
    final repo = ref.read(partyRepositoryProvider);
    if (id == null || repo == null) {
      if (mounted) setState(() => _resolving = false);
      return;
    }
    final party = await repo.getById(id);
    if (!mounted) return;
    setState(() {
      // A binned party must not open here: its ledger would still be reachable
      // from a link that no list shows any more.
      if (party == null || party.isDeleted) {
        _party = null;
        _partyMissing = true;
      } else {
        _party = party;
      }
      _resolving = false;
    });
  }

  /// The parties the picker offers, after the box above it.
  ///
  /// The list is uncapped now, so the dropdown needs a way in: building five
  /// thousand menu rows is what the old 500-cap was really protecting against.
  List<PartyEntity> _filterParties(List<PartyEntity> all) {
    final q = _partySearch.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where((p) =>
            p.name.toLowerCase().contains(q) ||
            (p.gstin ?? '').toLowerCase().contains(q) ||
            (p.phone ?? '').toLowerCase().contains(q))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(reportRepositoryProvider);
    final parties = ref.watch(partyRepositoryProvider);
    final firm = ref.watch(activeFirmProvider).valueOrNull;

    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AtriaPageHeader(
                  title: 'Statement of Account',
                  subtitle: 'Party ledger with PDF and Excel download',
                  compact: constraints.isCompact,
                ),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth:
                            constraints.isCompact ? double.infinity : 980,
                      ),
                      child: repository == null ||
                              firm == null ||
                              parties == null
                          ? const EmptyState(
                              icon: Icons.storefront_outlined,
                              title: 'No business open',
                              message:
                                  'Set up a business to view statements of account.',
                            )
                          : _body(repository, firm, parties),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _body(
    ReportRepository repository,
    FirmEntity firm,
    PartyRepository parties,
  ) {
    if (_resolving) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_partyMissing) {
      return EmptyState(
        icon: Icons.person_off_outlined,
        title: 'Party not found',
        message: 'That party is no longer in this business’s books — it was '
            'deleted, or the link is out of date. Go back and pick a party.',
        actionLabel: 'Go back',
        onAction: () => context.pop(),
      );
    }

    return StreamBuilder<List<PartyEntity>>(
      stream: _partiesStream(parties),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not load parties',
            message: atriaErrorMessage(snapshot.error, retry: 'Try again.'),
          );
        }

        final all = snapshot.data ?? const <PartyEntity>[];
        if (all.isEmpty) {
          return EmptyState(
            icon: Icons.people_outline_rounded,
            title: 'No parties yet',
            message:
                'Add a customer or supplier first — their ledger appears '
                'here with PDF and Excel downloads.',
            actionLabel: 'Add Party',
            onAction: () => context.push('/parties/new'),
          );
        }

        final filtered = _filterParties(all);
        if (filtered.isEmpty) {
          return EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No party matches “$_partySearch”',
            message: 'Clear the search to choose from all ${all.length} '
                'parties.',
            actionLabel: 'Clear search',
            onAction: () => setState(() {
              _partySearchController.clear();
              _partySearch = '';
            }),
          );
        }

        // Keep showing the picked party unless the search filtered it out —
        // `DropdownButton` asserts that exactly one item matches its value.
        final picked = filtered.any((p) => p.id == _party?.id)
            ? filtered.firstWhere((p) => p.id == _party!.id)
            : filtered.first;

        final isCompact = MediaQuery.sizeOf(context).width < 600;
        final partyDropdown = DropdownButtonFormField<PartyEntity>(
          key: ValueKey('party-${picked.id}'),
          iconSize: AppIconSize.md,
          initialValue: picked,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Party',
            prefixIcon: AtriaFieldIcon(Icons.person_outline_rounded),
          ),
          items: [
            for (final party in filtered)
              DropdownMenuItem(
                value: party,
                child: Text(
                  party.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) => setState(() => _party = value),
        );

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: isCompact
                  ? Column(
                      children: [
                        _partySearchField(all.length),
                        const SizedBox(height: 8),
                        partyDropdown,
                        const SizedBox(height: 8),
                        _rangeSelector,
                      ],
                    )
                  : Column(
                      children: [
                        Row(
                          children: [
                            Expanded(flex: 3, child: partyDropdown),
                            const SizedBox(width: 12),
                            Expanded(flex: 2, child: _rangeSelector),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _partySearchField(all.length),
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            _exportBar(repository, firm, picked),
            const SizedBox(height: 4),
            Expanded(child: _ledger(repository, picked)),
          ],
        );
      },
    );
  }

  Widget _partySearchField(int total) => TransactionSearchField(
        controller: _partySearchController,
        hintText: total > 12
            ? 'Search among $total parties'
            : 'Search name, GSTIN or phone',
        onChanged: (value) => setState(() => _partySearch = value),
        onClear: () => setState(() => _partySearch = ''),
      );

  /// The period strip, as a real [SegmentedButton].
  ///
  /// Same reasoning as the party editor's pills and `PartyStatementScreen`: the
  /// hand-rolled `GestureDetector` version was ~35dp tall with no focus node,
  /// so on Windows it could not be reached by Tab nor toggled with Space/Enter.
  /// The 48dp minimum is explicit because the app's theme sets
  /// `materialTapTargetSize: shrinkWrap`, which opts out of Material's 48dp tap
  /// target and leaves a segment at 40dp.
  Widget get _rangeSelector => SegmentedButton<_DateRange>(
        segments: [
          for (final range in _DateRange.values)
            ButtonSegment<_DateRange>(
              value: range,
              label: Text(
                switch (range) {
                  _DateRange.thisMonth => 'This Month',
                  _DateRange.thisFY => 'This FY',
                  _DateRange.allTime => 'All Time',
                },
              ),
            ),
        ],
        selected: {_range},
        showSelectedIcon: false,
        style: const ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, 48)),
        ),
        onSelectionChanged: (selection) =>
            setState(() => _range = selection.first),
      );

  Widget _exportBar(
    ReportRepository repository,
    FirmEntity firm,
    PartyEntity party,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // Never disabled for want of a party any more: the body refuses to render
    // without one, so an export already running is the only thing that turns
    // these off.
    final enabled = !_exporting;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(
            Icons.download_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
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
                ? () => _download(repository, firm, party, asExcel: false)
                : null,
            icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
            label: const Text('PDF'),
          ),
          const SizedBox(width: 10),
          FilledButton.tonalIcon(
            onPressed: enabled
                ? () => _download(repository, firm, party, asExcel: true)
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
    FirmEntity firm,
    PartyEntity party, {
    required bool asExcel,
  }) async {
    if (_exporting) return;
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
              statement: statement,
              firm: firm,
              from: _from,
              to: _to,
            )
          : await StatementExport.exportPdf(
              statement: statement,
              firm: firm,
              from: _from,
              to: _to,
            );
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            '${asExcel ? 'Excel' : 'PDF'} saved to Documents\\atria\\statements',
          ),
        ),
      );
      await OpenFilex.open(path);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Could not export: $e')));
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

  Widget _ledger(ReportRepository repository, PartyEntity party) {
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
            message: atriaErrorMessage(snapshot.error, retry: 'Try again.'),
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
          // "DATE & PARTICULARS" at labelSmall + 0.4 letter-spacing is ~120dp,
          // wider than the ~92dp a 4/14 share of a 360dp row gives it. The
          // label gives way rather than the row overflowing.
          Expanded(
            flex: 4,
            child: Text(
              'DATE & PARTICULARS',
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text('DEBIT', style: style, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 3,
            child: Text('CREDIT', style: style, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 4,
            child: Text('BALANCE', style: style, textAlign: TextAlign.right),
          ),
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
        const SizedBox(height: 2),
        MoneyText(
          amount,
          signMode: MoneySignMode.auto,
          style: text.titleMedium?.copyWith(
            fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
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
                // Compact, like the debit and credit cells beside it: a
                // running balance crosses a crore routinely, and the full
                // "₹1,00,00,000.00" is ~99dp against this column's ~91dp,
                // so it would paint across the Credit column.
                MoneyText(
                  line.balance,
                  signMode: MoneySignMode.auto,
                  compact: true,
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

  Widget _amountCell(BuildContext context, Decimal value, Color color) {
    if (value == Decimal.zero) {
      return const SizedBox();
    }
    final style = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: color, fontWeight: FontWeight.w700);
    return Align(
      alignment: Alignment.centerRight,
      child: MoneyText(value, compact: true, style: style),
    );
  }
}
