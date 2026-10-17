import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/party_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/responsive/platform_ui.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/whatsapp_links.dart';
import 'party_transactions_pane.dart';
import '../../shared/widgets/atria_avatar.dart';
import '../../shared/widgets/atria_list_page.dart';
import '../../shared/widgets/atria_list_toolbar.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/confirm_destructive.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/transaction_list.dart';
import '../../shared/widgets/mobile_page.dart';

enum _Filter { all, customers, suppliers }

final _mobilePartyTotalsProvider = StreamProvider<(Decimal, Decimal)>((
  ref,
) async* {
  final repo = ref.watch(partyRepositoryProvider);
  if (repo == null) {
    yield (Decimal.zero, Decimal.zero);
    return;
  }
  Future<(Decimal, Decimal)> totals() async {
    var collect = Decimal.zero;
    var pay = Decimal.zero;
    for (final party in await repo.all(limit: 0)) {
      final balance = Decimal.parse(
        (await repo.outstandingFor(party.id)).toStringAsFixed(2),
      );
      if (balance > Decimal.zero) {
        collect += balance;
      } else {
        pay -= balance;
      }
    }
    return (collect, pay);
  }

  yield await totals();
  await for (final _ in repo.watchOutstandingChanges()) {
    yield await totals();
  }
});

/// A party's live outstanding.
///
/// The parties list lives under the nav shell's `IndexedStack`, so it is never
/// rebuilt when a payment is recorded in another tab — and the old cached
/// `Future` made it worse: even a rebuild handed `FutureBuilder` the same
/// completed future, which never re-runs. The Outstanding column therefore
/// froze at whatever it read when the row was first built, for the life of the
/// session.
///
/// This is the fix `providers.itemMovementSignalProvider` already applies to
/// the cached `currentStock` balances: read the value, then re-read it whenever
/// the tables it is built from change. No polling, and no focus signal to plumb
/// through the router. `autoDispose` so a row scrolled off screen releases its
/// drift subscription.
final _outstandingProvider = StreamProvider.autoDispose.family<double, String>((
  ref,
  partyId,
) async* {
  final repo = ref.watch(partyRepositoryProvider);
  if (repo == null) return;
  yield await repo.outstandingFor(partyId);
  await for (final _ in repo.watchOutstandingChanges()) {
    yield await repo.outstandingFor(partyId);
  }
});

class PartiesScreen extends ConsumerStatefulWidget {
  const PartiesScreen({super.key, this.initialType});

  /// `customer` / `supplier` — the left navigation reaches the same screen
  /// through two different rows (QBO keeps Customers and Vendors apart), so
  /// the filter has to be preselectable from the URL.
  final String? initialType;

  @override
  ConsumerState<PartiesScreen> createState() => _PartiesScreenState();
}

class _PartiesScreenState extends ConsumerState<PartiesScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// Which slice of parties this list shows, read from the route on **every**
  /// build rather than latched into a field.
  ///
  /// Same defect as the Sales and Purchase lists: the IndexedStack shell reuses
  /// this State across `/parties?type=customer` → `/parties?type=supplier`, so
  /// a `late` field written once left the heading and the "New vendor" button
  /// naming the wrong side of the ledger for the rest of the session.
  _Filter get _filter => switch (widget.initialType) {
    'customer' => _Filter.customers,
    'supplier' => _Filter.suppliers,
    _ => _Filter.all,
  };

  String _search = '';
  Timer? _debounce;

  /// Party shown in the desktop right pane (master-detail). Null = prompt.
  PartyEntity? _selected;

  Stream<List<PartyEntity>>? _stream;
  String? _streamKey;
  PartyRepository? _streamRepo;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  String? get _typeFilter {
    switch (_filter) {
      case _Filter.all:
        return null;
      case _Filter.customers:
        return 'customer';
      case _Filter.suppliers:
        return 'supplier';
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _search = value.trim());
    });
  }

  Stream<List<PartyEntity>> _streamFor(PartyRepository repo) {
    final key = '${_filter.name}|$_search';
    if (_stream == null || _streamKey != key || _streamRepo != repo) {
      _streamKey = key;
      _streamRepo = repo;
      _stream = repo.watchAll(type: _typeFilter, search: _search);
    }
    return _stream!;
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(partyRepositoryProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Desktop: Vyapar-style master-detail — party list left, the
        // selected party's transactions right (no more wasted width, no more
        // action-sheet-first navigation on a 1500px screen).
        final masterDetail =
            !Theme.of(context).platform.isMobileUi &&
            constraints.maxWidth >= Breakpoints.medium;
        return AtriaListPage(
          title: _filter == _Filter.suppliers ? 'Vendors' : 'Parties',
          mobileHeader: _mobileTabs(),
          toolbar: [if (Theme.of(context).platform.isMobileUi) _mobileTotals()],
          actions: [
            if (repo != null)
              AtriaPrimaryAction(
                label: _filter == _Filter.suppliers
                    ? 'New vendor'
                    : 'New party',
                onPressed: () => context.push(
                  '/parties/new?type='
                  '${_filter == _Filter.suppliers ? 'supplier' : 'customer'}',
                ),
              ),
          ],
          search: _searchBar,
          filters: [
            if (!Theme.of(context).platform.isMobileUi)
              AtriaAdaptiveFilter<_Filter>(
                label: 'Type',
                scrollable: false,
                value: _filter,
                onChanged: (f) => context.go(switch (f) {
                  _Filter.all => '/parties',
                  _Filter.customers => '/parties?type=customer',
                  _Filter.suppliers => '/parties?type=supplier',
                }),
                segments: const [
                  AtriaSegment(value: _Filter.all, label: 'All'),
                  AtriaSegment(value: _Filter.customers, label: 'Customers'),
                  AtriaSegment(value: _Filter.suppliers, label: 'Vendors'),
                ],
              ),
          ],
          body: repo == null
              ? _noFirmState
              : masterDetail
              ? PartiesMasterDetail(
                  list: _list(repo, masterDetail: true),
                  selectedParty: _selected,
                )
              : _list(repo),
        );
      },
    );
  }

  Widget _mobileTabs() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          for (final tab in [
            ('All', null, _Filter.all),
            ('Customers', 'customer', _Filter.customers),
            ('Vendors', 'supplier', _Filter.suppliers),
          ])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Material(
                  color: _filter == tab.$3 ? scheme.primary : scheme.surface,
                  borderRadius: BorderRadius.circular(24),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () => context.go(
                      tab.$2 == null ? '/parties' : '/parties?type=${tab.$2}',
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 4,
                      ),
                      child: Text(
                        tab.$1,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: _filter == tab.$3
                                  ? scheme.onPrimary
                                  : scheme.onSurface,
                            ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _mobileTotals() {
    final totals = ref.watch(_mobilePartyTotalsProvider);
    return totals.when(
      loading: () => const LinearProgressIndicator(),
      error: (_, _) => const Text('Could not load party balances'),
      data: (totals) => AtriaCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Outstanding balances',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final entry in [
                  (
                    'To receive',
                    totals.$1,
                    Theme.of(context).colorScheme.primary,
                  ),
                  ('To pay', totals.$2, Theme.of(context).colorScheme.error),
                ]) ...[
                  if (entry.$1 == 'To pay') const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.$1,
                            style: TextStyle(color: entry.$3, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          MobileAmount(
                            entry.$2,
                            style: TextStyle(
                              color: entry.$3,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // The shared field, not a hand-rolled pill: this was the only list in the
  // app whose search box was a fully-round pill, which made Parties look like
  // a different app from Sales next to it.
  Widget get _searchBar => TransactionSearchField(
    controller: _searchController,
    hintText: 'Search name, phone or GSTIN',
    onChanged: _onSearchChanged,
    onClear: () {
      // clear() doesn't fire onChanged, so the debounce that is still pending
      // would put the old query back a moment after the field looked empty.
      _debounce?.cancel();
      _searchController.clear();
      _searchFocus.unfocus();
      setState(() => _search = '');
    },
  );

  Widget get _noFirmState => const EmptyState(
    icon: Icons.storefront_outlined,
    title: 'No business open',
    message:
        'Set up a firm in Settings to start managing customers and '
        'suppliers.',
  );

  Widget _list(PartyRepository repo, {bool masterDetail = false}) {
    return StreamBuilder<List<PartyEntity>>(
      stream: _streamFor(repo),
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

        var parties = snapshot.data ?? const <PartyEntity>[];
        // Keep the pane selection valid as the list filters/changes —
        // scheduled post-frame instead of mutating state during build.
        if (_selected != null && !parties.any((p) => p.id == _selected!.id)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _selected != null) {
              setState(() => _selected = null);
            }
          });
        }
        if (parties.isEmpty) {
          return CustomScrollView(
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: _search.isEmpty
                      ? Icons.people_outline_rounded
                      : Icons.search_off_rounded,
                  title: _search.isEmpty ? 'No parties yet' : 'No matches',
                  message: _search.isEmpty
                      ? 'Add your first customer or supplier to start '
                            'recording transactions.'
                      : 'Nothing matches “$_search”. Try a different name, '
                            'phone number or GSTIN.',
                  actionLabel: _search.isEmpty ? 'Add Party' : null,
                  onAction: _search.isEmpty
                      ? () => context.push('/parties/new')
                      : null,
                ),
              ),
            ],
          );
        }

        if (Theme.of(context).platform.isMobileUi) {
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: parties.length + 1,
            itemBuilder: (context, index) => index == 0
                ? AtriaResultsBar(
                    count: parties.length,
                    noun: 'party',
                    filtered: _search.isNotEmpty || _filter != _Filter.all,
                  )
                : Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _PartyRow(
                      party: parties[index - 1],
                      onTap: () => _showActions(parties[index - 1], repo),
                      onSecondaryTap: () =>
                          _showActions(parties[index - 1], repo),
                    ),
                  ),
          );
        }
        return Column(
          children: [
            AtriaResultsBar(
              count: parties.length,
              noun: 'party',
              filtered: _search.isNotEmpty || _filter != _Filter.all,
            ),
            Expanded(
              child: Scrollbar(
                child: ListView.separated(
                  // The page frame owns the gutter now; only the master-detail
                  // split keeps a tighter inset, against the detail pane.
                  padding: EdgeInsets.fromLTRB(
                    masterDetail ? AppSpace.sm : 0,
                    AppSpace.xxs,
                    masterDetail ? AppSpace.sm : 0,
                    96,
                  ),
                  itemCount: parties.length,
                  separatorBuilder: (_, _) =>
                      SizedBox(height: masterDetail ? 2 : 10),
                  itemBuilder: (context, index) {
                    final selected =
                        masterDetail && parties[index].id == _selected?.id;
                    return _PartyRow(
                      party: parties[index],
                      dense: masterDetail,
                      selected: selected,
                      // Desktop: tap selects for the right pane (kebab/long-press
                      // still opens actions). Phone: tap opens the action sheet.
                      onTap: masterDetail
                          ? () => setState(() => _selected = parties[index])
                          : () => _showActions(parties[index], repo),
                      onSecondaryTap: () => _showActions(parties[index], repo),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showActions(PartyEntity party, PartyRepository repo) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _ActionSheet(party: party, repo: repo),
    );
  }
}

class _PartyRow extends ConsumerWidget {
  const _PartyRow({
    required this.party,
    required this.onTap,
    this.onSecondaryTap,
    this.dense = false,
    this.selected = false,
  });

  final PartyEntity party;
  final VoidCallback onTap;

  /// Desktop master-detail: right-click / long-press still opens the full
  /// action sheet even though a plain tap only selects the row.
  final VoidCallback? onSecondaryTap;

  /// Compact master-detail row (no card chrome; selection highlight instead).
  final bool dense;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Recreated whenever this party's books move — see [_outstandingProvider].
    final outstanding = ref.watch(_outstandingProvider(party.id));

    if (dense) {
      return Material(
        color: selected
            ? Theme.of(context).colorScheme.primaryContainer
                  .withValues(alpha: 0.55)
            : Colors.transparent,
        borderRadius: AppRadius.mdAll,
        // Without this the row's ink splash paints a square over the rounded
        // corners it is drawn with — visible on every master-detail row.
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onSecondaryTap: onSecondaryTap,
          onLongPress: onSecondaryTap,
          borderRadius: AppRadius.mdAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: _rowBody(context, outstanding, compact: true),
          ),
        ),
      );
    }
    return AtriaCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: _rowBody(
        context,
        outstanding,
        compact: Theme.of(context).platform.isMobileUi,
      ),
    );
  }

  Widget _rowBody(
    BuildContext context,
    AsyncValue<double> outstanding, {
    bool compact = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final p = party;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AtriaAvatar.initials(
          name: p.name,
          radius: compact ? AtriaAvatar.row : AtriaAvatar.header,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.gstin != null && p.gstin!.trim().isNotEmpty) ...[
                    Flexible(
                      child: Text(
                        _maskGstin(p.gstin!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          letterSpacing: 0.4,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (p.phone != null && p.phone!.trim().isNotEmpty)
                    Flexible(
                      child: Text(
                        _formatPhone(p.phone!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _OutstandingCell(outstanding: outstanding, compact: compact),
      ],
    );
  }
}

class _OutstandingCell extends StatelessWidget {
  const _OutstandingCell({required this.outstanding, this.compact = false});

  /// Live value, not a one-shot future — see [_outstandingProvider].
  final AsyncValue<double> outstanding;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = atriaColors(context);

    return outstanding.when(
      loading: () => const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2.2),
      ),
      error: (_, _) =>
          Icon(Icons.error_outline_rounded, size: 18, color: colors.negative),
      data: (value) {
        final decimal = Decimal.parse(value.toStringAsFixed(2));
        final isReceivable = value > 0.005;
        final isPayable = value < -0.005;
        final settled = !isReceivable && !isPayable;

        if (Theme.of(context).platform.isMobileUi && settled) {
          return Text(
            'No dues',
            style: text.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            MoneyText(
              decimal,
              compact: true,
              signMode: MoneySignMode.always,
              style: (compact ? text.bodySmall : text.titleSmall)?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (!compact) ...[
              const SizedBox(height: 2),
              Text(
                settled
                    ? 'Settled'
                    : isReceivable
                    ? 'Receivable'
                    : 'Payable',
                style: text.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: settled
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : isReceivable
                      ? colors.positive
                      : colors.negative,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ActionSheet extends StatelessWidget {
  const _ActionSheet({required this.party, required this.repo});

  final PartyEntity party;
  final PartyRepository repo;

  String get _digits => (party.phone ?? '').replaceAll(RegExp(r'[^\d]'), '');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final colors = atriaColors(context);
    final hasPhone = _digits.length == 10;

    return SafeArea(
      minimum: const EdgeInsets.only(bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                AtriaAvatar.initials(
                  name: party.name,
                  radius: AtriaAvatar.header,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        party.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          switch (party.type) {
                            'customer' => 'Customer',
                            'supplier' => 'Supplier',
                            _ => 'Customer & Supplier',
                          },
                          if (party.gstin != null &&
                              party.gstin!.trim().isNotEmpty)
                            party.gstin!.toUpperCase(),
                          if (hasPhone) _formatPhone(party.phone!),
                        ].join('  •  '),
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(color: scheme.outline, height: 1),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.receipt_long_rounded),
            title: const Text('View Statement'),
            subtitle: const Text('Ledger and running balance'),
            onTap: () {
              // Resolve the router BEFORE dismissing the sheet: popping
              // deactivates this context, and `context.push` afterwards
              // looks up `GoRouter.of` on a dead element.
              final router = GoRouter.of(context);
              Navigator.of(context).pop();
              router.push('/parties/statement/${party.id}');
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_rounded),
            title: const Text('Edit Party'),
            onTap: () {
              final router = GoRouter.of(context);
              Navigator.of(context).pop();
              router.push('/parties/edit/${party.id}');
            },
          ),
          ListTile(
            leading: Icon(
              Icons.call_rounded,
              color: hasPhone ? colors.positive : scheme.onSurfaceVariant,
            ),
            title: const Text('Call'),
            enabled: hasPhone,
            onTap: hasPhone
                ? () {
                    Navigator.of(context).pop();
                    launchUrl(Uri.parse('tel:${party.phone}'));
                  }
                : null,
          ),
          ListTile(
            leading: const Icon(Icons.chat_rounded),
            title: const Text('WhatsApp'),
            enabled: hasPhone,
            onTap: hasPhone
                ? () {
                    Navigator.of(context).pop();
                    launchUrl(WhatsAppLinks.chat(_digits));
                  }
                : null,
          ),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: colors.negative),
            title: Text(
              'Delete Party',
              style: TextStyle(color: colors.negative),
            ),
            onTap: () async {
              // Confirm before dismissing the sheet — popping first unmounts
              // this context, so the confirmation dialog would be shown with a
              // dead context and the "deleted" snackbar could never appear.
              final navigator = Navigator.of(context);
              final messenger = ScaffoldMessenger.maybeOf(context);
              final deleted = await _confirmDelete(context);
              if (!deleted) return;
              await navigator.maybePop();
              try {
                await repo.delete(party.id);
              } catch (e) {
                messenger?.showSnackBar(
                  SnackBar(content: Text('Could not delete party: $e')),
                );
                return;
              }
              messenger?.showSnackBar(
                const SnackBar(content: Text('Party deleted')),
              );
            },
          ),
        ],
      ),
    );
  }
}

String _maskGstin(String gstin) {
  final v = gstin.trim().toUpperCase();
  if (v.length != 15) return v;
  return '${v.substring(0, 2)}•••••${v.substring(10)}';
}

String _formatPhone(String phone) {
  final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
  if (digits.length == 10) {
    return '+91 ${digits.substring(0, 5)} ${digits.substring(5)}';
  }
  return phone.trim();
}

Future<bool> _confirmDelete(BuildContext context) {
  return confirmDestructive(
    context,
    title: 'Delete party?',
    message:
        'This removes the party from your books. Existing invoices and '
        'bills are kept, but will no longer be linked to this party.',
  );
}
