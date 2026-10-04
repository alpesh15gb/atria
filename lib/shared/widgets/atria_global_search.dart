import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/app_database.dart';
import '../../core/navigation/nav_destinations.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/atria_field_icon.dart';

/// Opens the global search panel from anywhere in the chrome.
///
/// QBO's top-bar search is a *product-wide* find: it reaches pages and
/// documents, not just the list you are standing on (each list keeps its own
/// filter field for that). This panel is the same idea, scoped to what Atria
/// actually stores — every navigation page, plus invoices.
Future<void> showAtriaGlobalSearch(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    builder: (dialogContext) => const _GlobalSearchDialog(),
  );
}

class _GlobalSearchDialog extends ConsumerStatefulWidget {
  const _GlobalSearchDialog();

  @override
  ConsumerState<_GlobalSearchDialog> createState() =>
      _GlobalSearchDialogState();
}

class _GlobalSearchDialogState extends ConsumerState<_GlobalSearchDialog> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Every page the app has, flattened out of the rail's sections.
  List<NavSectionEntry> get _pages {
    final entries = <NavSectionEntry>[];
    for (final section in NavDestinations.sections) {
      entries.addAll(section.entries);
    }
    return entries;
  }

  List<NavSectionEntry> get _matchingPages {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _pages.take(6).toList();
    return _pages
        .where((e) => e.label.toLowerCase().contains(q))
        .take(6)
        .toList();
  }

  void _go(String route) {
    // Capture the router before dismissing the dialog; the context is dead
    // once the route pops.
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    // A rail row that carries a query string cannot go through goBranch, so it
    // is pushed; a bare path is the branch root and is a plain `go`.
    if (route.contains('?')) {
      router.push(route);
    } else {
      router.go(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pages = _matchingPages;
    final showDocs = _query.trim().length >= 2;

    // The panel is a modal over the whole window — there is no pane behind it
    // whose width the inset should be measured from — so the window
    // size is the right basis here, and this is the one place in the panel
    // that legitimately reads MediaQuery.
    //
    // The old inset was a hard 40dp each side, and Material's own `Dialog`
    // forces a 280dp minimum width: under ~360dp the inset left less than that
    // and the panel overhung its own inset instead of filling it, so a 320dp
    // phone got a cramped box floating in the middle of a wider screen. Below
    // [Breakpoints.medium] the inset drops to a gutter and the panel simply
    // takes the screen.
    //
    // The vertical inset gives way on a short window too — and the new Windows
    // minimum size (see `windows/runner/win32_window.cpp`) is exactly that case:
    // at 160dp tall a 90dp inset left no room for the search field, let alone
    // results. Whatever is left over the field goes to the result list, which
    // is a `Flexible` and therefore shrinks rather than overflowing.
    final window = MediaQuery.sizeOf(context);
    final tight = window.width < Breakpoints.medium;
    final short = window.height < 560;
    final inset = EdgeInsets.symmetric(
      horizontal: tight ? 12 : 40,
      vertical: short ? 12 : (tight ? 48 : 90),
    );

    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: inset,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 620,
          // The space the inset leaves, floored at a field plus a couple of
          // rows and capped at the 520dp this panel has always been.
          maxHeight:
              (window.height - inset.vertical - 16).clamp(140.0, 520.0),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  hintText: 'Search pages, parties, items and invoices',
                  prefixIcon: AtriaFieldIcon(
                    PhosphorIconsRegular.magnifyingGlass,
                    size: 18,
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: scheme.outline),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  if (pages.isNotEmpty) ...[
                    _heading(context, _query.trim().isEmpty
                        ? 'GO TO'
                        : 'PAGES'),
                    for (final page in pages)
                      _ResultTile(
                        icon: page.icon,
                        title: page.label,
                        onTap: () => _go(page.route),
                      ),
                  ],
                  if (showDocs) ...[
                    _heading(context, 'INVOICES'),
                    _InvoiceResults(
                      query: _query.trim(),
                      onOpen: (id) => _push('/sales/detail/$id'),
                    ),
                    _heading(context, 'PARTIES'),
                    _PartyResults(
                      query: _query.trim(),
                      onOpen: (id) => _push('/parties/statement/$id'),
                    ),
                    _heading(context, 'ITEMS'),
                    _ItemResults(
                      query: _query.trim(),
                      onOpen: (id) => _push('/items/edit/$id'),
                    ),
                  ],
                ],
              ),
            ),
            if (pages.isEmpty && !showDocs)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 22),
                child: Text(
                  'Nothing matches “${_query.trim()}”.',
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Pushes a detail route after closing the panel.
  ///
  /// The router is captured before the dialog is dismissed: after `pop` this
  /// context is deactivated and `GoRouter.of` has nothing to find.
  void _push(String route) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.push(route);
  }

  Widget _heading(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

/// Live invoice matches, streamed from the sales repository. Only built once
/// the user has typed something, so opening the panel starts no query.
class _InvoiceResults extends ConsumerWidget {
  const _InvoiceResults({required this.query, required this.onOpen});

  final String query;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(salesRepositoryProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    if (sales == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
        child: Text(
          'Choose a business first.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }

    return StreamBuilder<List<SalesInvoiceEntity>>(
      stream: sales.watchList(search: query, limit: 6),
      builder: (context, snapshot) {
        final rows = snapshot.data ?? const <SalesInvoiceEntity>[];
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _SearchSpinner();
        }
        if (rows.isEmpty) return _NoMatch(what: 'invoices', query: query);
        return Column(
          children: [
            for (final doc in rows)
              _ResultTile(
                icon: PhosphorIconsRegular.receipt,
                title: doc.partyName ?? 'Walk-in customer',
                subtitle: '${doc.number}  ·  '
                    '${Formatters.money(Money.of(doc.grandTotal))}',
                onTap: () => onOpen(doc.id),
              ),
          ],
        );
      },
    );
  }
}

/// Live party matches. A name, a phone number or a GSTIN all find the same
/// person, which is how a shop recognises a customer when the invoice is not
/// in front of them.
class _PartyResults extends ConsumerWidget {
  const _PartyResults({required this.query, required this.onOpen});

  final String query;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parties = ref.watch(partyRepositoryProvider);
    if (parties == null) return const _NoFirm();
    return StreamBuilder<List<PartyEntity>>(
      stream: parties.watchAll(search: query),
      builder: (context, snapshot) {
        final rows = (snapshot.data ?? const <PartyEntity>[]).take(5).toList();
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _SearchSpinner();
        }
        if (rows.isEmpty) return _NoMatch(what: 'parties', query: query);
        return Column(
          children: [
            for (final party in rows)
              _ResultTile(
                icon: party.type == 'supplier'
                    ? PhosphorIconsRegular.storefront
                    : PhosphorIconsRegular.user,
                title: party.name,
                subtitle: [
                  party.type == 'both' ? 'Customer & supplier' : party.type,
                  if ((party.phone ?? '').isNotEmpty) party.phone!,
                  if ((party.gstin ?? '').isNotEmpty) party.gstin!,
                ].join('  ·  '),
                onTap: () => onOpen(party.id),
              ),
          ],
        );
      },
    );
  }
}

/// Live item matches — by name, SKU or barcode.
class _ItemResults extends ConsumerWidget {
  const _ItemResults({required this.query, required this.onOpen});

  final String query;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(itemRepositoryProvider);
    if (items == null) return const _NoFirm();
    return StreamBuilder<List<ItemEntity>>(
      stream: items.watchAll(search: query, limit: 5),
      builder: (context, snapshot) {
        final rows = snapshot.data ?? const <ItemEntity>[];
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _SearchSpinner();
        }
        if (rows.isEmpty) return _NoMatch(what: 'items', query: query);
        return Column(
          children: [
            for (final item in rows)
              _ResultTile(
                icon: item.isService
                    ? PhosphorIconsRegular.wrench
                    : PhosphorIconsRegular.cube,
                title: item.name,
                subtitle: [
                  if ((item.sku ?? '').isNotEmpty) 'SKU ${item.sku}',
                  Formatters.money(Money.of(item.salePrice)),
                  if (item.stockType == 'tracked')
                    '${item.currentStock.toStringAsFixed(item.currentStock == item.currentStock.roundToDouble() ? 0 : 2)} ${item.unit} in stock',
                ].join('  ·  '),
                onTap: () => onOpen(item.id),
              ),
          ],
        );
      },
    );
  }
}

class _NoFirm extends StatelessWidget {
  const _NoFirm();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Text(
        'Choose a business first.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.what, required this.query});

  final String what;
  final String query;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Text(
        'No $what match “$query”.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _SearchSpinner extends StatelessWidget {
  const _SearchSpinner();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodyMedium,
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
      onTap: onTap,
    );
  }
}
