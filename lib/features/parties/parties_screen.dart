import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/party_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/whatsapp_links.dart';
import 'party_transactions_pane.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';

enum _Filter { all, customers, suppliers }

class PartiesScreen extends ConsumerStatefulWidget {
  const PartiesScreen({super.key});

  @override
  ConsumerState<PartiesScreen> createState() => _PartiesScreenState();
}

class _PartiesScreenState extends ConsumerState<PartiesScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  _Filter _filter = _Filter.all;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Parties'),
        actions: [
          IconButton(
            tooltip: 'Add party',
            onPressed: repo == null ? null : () => context.push('/parties/new'),
            icon: const Icon(Icons.person_add_rounded),
          ),
        ],
      ),
      floatingActionButton: repo == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => context.push('/parties/new'),
              icon: const Icon(Icons.person_add_rounded),
              label: const Text('Add Party'),
            ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Desktop: Vyapar-style master-detail — party list left, the
            // selected party's transactions right (no more wasted width, no
            // more action-sheet-first navigation on a 1500px screen).
            if (constraints.maxWidth >= Breakpoints.medium) {
              return Column(
                children: [
                  _searchBar,
                  const SizedBox(height: 10),
                  _filterPills,
                  const SizedBox(height: 12),
                  Expanded(
                    child: repo == null
                        ? _noFirmState
                        : PartiesMasterDetail(
                            list: _list(repo, masterDetail: true),
                            selectedParty: _selected,
                          ),
                  ),
                ],
              );
            }
            return Column(
              children: [
                _searchBar,
                const SizedBox(height: 10),
                _filterPills,
                const SizedBox(height: 12),
                Expanded(
                  child: repo == null ? _noFirmState : _list(repo),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget get _searchBar => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocus,
          onChanged: _onSearchChanged,
          textInputAction: TextInputAction.search,
          keyboardType: TextInputType.name,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _search.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    onPressed: () {
                      // clear() doesn't fire onChanged, so the debounce that
                      // is still pending would put the old query back a moment
                      // after the field looked empty.
                      _debounce?.cancel();
                      _searchController.clear();
                      _searchFocus.unfocus();
                      setState(() => _search = '');
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
            hintText: 'Search name, phone or GSTIN',
            border: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(999)),
            ),
          ),
        ),
      );

  Widget get _filterPills => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            children: [
              for (final f in _Filter.values)
                Expanded(
                  child: _pill(f),
                ),
            ],
          ),
        ),
      );

  Widget _pill(_Filter f) {
    final selected = _filter == f;
    final scheme = Theme.of(context).colorScheme;
    // Material+InkWell instead of a bare GestureDetector so the press
    // ripples — the pill used to swallow taps without any feedback.
    return Material(
      color: selected ? scheme.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: () => setState(() => _filter = f),
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.10),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            switch (f) {
              _Filter.all => 'All',
              _Filter.customers => 'Customers',
              _Filter.suppliers => 'Suppliers',
            },
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
          ),
        ),
      ),
    );
  }

  Widget get _noFirmState => const EmptyState(
        icon: Icons.storefront_outlined,
        title: 'No business open',
        message: 'Set up a firm in Settings to start managing customers and '
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
            message: '${snapshot.error}',
          );
        }

        var parties = snapshot.data ?? const <PartyEntity>[];
        // Keep the pane selection valid as the list filters/changes —
        // scheduled post-frame instead of mutating state during build.
        if (_selected != null &&
            !parties.any((p) => p.id == _selected!.id)) {
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

        return Scrollbar(
          child: ListView.separated(
            padding: EdgeInsets.fromLTRB(
                masterDetail ? 8 : 16, 2, masterDetail ? 8 : 16, 96),
            itemCount: parties.length,
            separatorBuilder: (_, _) =>
                SizedBox(height: masterDetail ? 2 : 10),
            itemBuilder: (context, index) {
              final selected = masterDetail && parties[index].id == _selected?.id;
              return _PartyRow(
                party: parties[index],
                repo: repo,
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

class _PartyRow extends StatefulWidget {
  const _PartyRow({
    required this.party,
    required this.repo,
    required this.onTap,
    this.onSecondaryTap,
    this.dense = false,
    this.selected = false,
  });

  final PartyEntity party;
  final PartyRepository repo;
  final VoidCallback onTap;

  /// Desktop master-detail: right-click / long-press still opens the full
  /// action sheet even though a plain tap only selects the row.
  final VoidCallback? onSecondaryTap;

  /// Compact master-detail row (no card chrome; selection highlight instead).
  final bool dense;
  final bool selected;

  @override
  State<_PartyRow> createState() => _PartyRowState();
}

class _PartyRowState extends State<_PartyRow> {
  // A ListView reuses State objects as rows shift around, so a `late final`
  // future would keep party A's balance after the row was recycled for party
  // B. Key the cache on the party itself.
  Future<double>? _outstanding;
  String? _outstandingFor;

  Future<double> get _outstandingFuture {
    if (_outstanding == null || _outstandingFor != widget.party.id) {
      _outstandingFor = widget.party.id;
      _outstanding = widget.repo.outstandingFor(widget.party.id);
    }
    return _outstanding!;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (widget.dense) {
      return Material(
        color: widget.selected
            ? scheme.primaryContainer.withValues(alpha: 0.55)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: widget.onTap,
          onSecondaryTap: widget.onSecondaryTap,
          onLongPress: widget.onSecondaryTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: _rowBody(context, compact: true),
          ),
        ),
      );
    }
    return AtriaCard(
      onTap: widget.onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: _rowBody(context),
    );
  }

  Widget _rowBody(BuildContext context, {bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final p = widget.party;
    return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _Avatar(name: p.name, radius: compact ? 18 : 22),
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
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
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
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _OutstandingCell(future: _outstandingFuture, compact: compact),
        ],
    );
  }
}

class _OutstandingCell extends StatelessWidget {
  const _OutstandingCell({required this.future, this.compact = false});

  final Future<double> future;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = atriaColors(context);

    return FutureBuilder<double>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          );
        }
        if (snapshot.hasError) {
          return Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: colors.negative,
          );
        }

        final value = snapshot.data ?? 0;
        final decimal = Decimal.parse(value.toStringAsFixed(2));
        final isReceivable = value > 0.005;
        final isPayable = value < -0.005;
        final settled = !isReceivable && !isPayable;

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
                settled ? 'Settled' : isReceivable ? 'Receivable' : 'Payable',
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

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.radius});

  final String name;
  final double radius;

  static const List<Color> _palette = [
    Color(0xFF0369A1),
    Color(0xFF1D4ED8),
    Color(0xFFB45309),
    Color(0xFF6D28D9),
    Color(0xFFBE123C),
    Color(0xFF0E7490),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _palette[name.hashCode % _palette.length];

    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        color: color.withValues(alpha: scheme.brightness == Brightness.dark
            ? 0.26
            : 0.14),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        _initials(name),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: radius * 0.82,
          height: 1.1,
        ),
      ),
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
                _Avatar(name: party.name, radius: 24),
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
              Navigator.of(context).pop();
              context.push('/parties/statement/${party.id}');
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_rounded),
            title: const Text('Edit Party'),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/parties/edit/${party.id}');
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
            leading: Icon(
              Icons.delete_outline_rounded,
              color: colors.negative,
            ),
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

String _initials(String name) {
  final parts =
      name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    return parts.first.characters.first.toUpperCase();
  }
  return '${parts.first.characters.first}${parts[1].characters.first}'
      .toUpperCase();
}

Future<bool> _confirmDelete(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete party?'),
      content: const Text(
        'This removes the party from your books. Existing invoices and bills '
        'are kept, but will no longer be linked to this party.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
            foregroundColor: Theme.of(dialogContext).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return result ?? false;
}
