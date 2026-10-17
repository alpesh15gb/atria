import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/gst.dart';
import '../../core/constants/units.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/item_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/responsive/platform_ui.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../core/theme/app_sizes.dart';
import '../../shared/widgets/atria_list_toolbar.dart';
import '../../shared/widgets/atria_list_page.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/confirm_destructive.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/mobile_page.dart';
import '../../shared/widgets/status_chip.dart';
import '../../shared/widgets/transaction_list.dart';

enum _ItemFilter { all, lowStock, services }

final _itemFilterProvider = StateProvider<_ItemFilter>(
  (ref) => _ItemFilter.all,
);
final _itemSearchProvider = StateProvider<String>((ref) => '');

/// The whole catalogue, watched with NO row cap and no search term.
///
/// Used only for the two totals, which must describe every item — a stock value
/// computed from a page of the catalogue is simply wrong.
///
/// This used to be `repo.watchAll()` at its default cap of 1000, and the list
/// below was filtered from THAT in memory: anything past the first thousand
/// rows alphabetically could neither be seen nor searched, while the search box
/// claimed "Search name, SKU, HSN or barcode" and answered "No matching items".
/// Because the cap is gone here, the list is no longer truncated and there is
/// nothing left for the screen to warn about.
final _allItemsProvider = StreamProvider<List<ItemEntity>>((ref) {
  final repo = ref.watch(itemRepositoryProvider);
  if (repo == null) return Stream.value(const <ItemEntity>[]);
  return repo.watchAll(limit: 0);
});

/// The rows the grid renders.
///
/// Search runs in SQL over every row (the repository's LIKE covers name, SKU,
/// HSN and barcode), so it is unbounded and reactive. Only the chip filter is
/// applied in memory: `lowStock` and `services` are column predicates, and
/// pushing them down would mean three near-identical queries for no gain on a
/// list that is already local.
final _visibleItemsProvider = StreamProvider<List<ItemEntity>>((ref) {
  final repo = ref.watch(itemRepositoryProvider);
  if (repo == null) return Stream.value(const <ItemEntity>[]);
  final filter = ref.watch(_itemFilterProvider);
  final search = ref.watch(_itemSearchProvider);
  return repo
      .watchAll(search: search, limit: 0)
      .map((items) => _applyChip(items, filter));
});

List<ItemEntity> _applyChip(List<ItemEntity> items, _ItemFilter filter) =>
    switch (filter) {
      _ItemFilter.all => items,
      _ItemFilter.lowStock => items.where(_isLowStock).toList(growable: false),
      _ItemFilter.services =>
        items.where((item) => item.isService).toList(growable: false),
    };

bool _isLowStock(ItemEntity item) =>
    !item.isService &&
    item.stockType == 'tracked' &&
    item.lowStockAlert > 0 &&
    item.currentStock <= item.lowStockAlert;

class _StockStats {
  const _StockStats({required this.saleValue, required this.lowCount});

  final Decimal saleValue;
  final int lowCount;
}

_StockStats _computeStats(List<ItemEntity> items) {
  var sale = Decimal.zero;
  var low = 0;
  for (final item in items) {
    // Services carry no stock; the movement writer skips them, so leaving one
    // tracked would freeze its opening balance in these totals forever.
    if (item.isService || item.stockType != 'tracked') continue;
    sale += Money.mulN(Money.of(item.currentStock), item.salePrice);
    if (_isLowStock(item)) low++;
  }
  return _StockStats(saleValue: sale, lowCount: low);
}

String _filterLabel(_ItemFilter filter) => switch (filter) {
  _ItemFilter.all => 'All',
  _ItemFilter.lowStock => 'Low stock',
  _ItemFilter.services => 'Services',
};

IconData _filterIcon(_ItemFilter filter) => switch (filter) {
  _ItemFilter.all => Icons.grid_view_rounded,
  _ItemFilter.lowStock => Icons.warning_amber_rounded,
  _ItemFilter.services => Icons.miscellaneous_services_rounded,
};

class ItemsScreen extends ConsumerStatefulWidget {
  const ItemsScreen({super.key});

  @override
  ConsumerState<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends ConsumerState<ItemsScreen> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  int _crossAxisCount(WindowSize size) => switch (size) {
    WindowSize.compact => 1,
    WindowSize.medium => 2,
    WindowSize.expanded => 3,
    WindowSize.large => 4,
  };

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(itemRepositoryProvider);
    final visible = ref.watch(_visibleItemsProvider);
    final stats = _computeStats(
      ref.watch(_allItemsProvider).valueOrNull ?? const [],
    );
    final search = ref.watch(_itemSearchProvider);
    final filter = ref.watch(_itemFilterProvider);

    // The shared page frame owns the heading, its inset and the position of
    // the actions, so this page lines up with every other list. The body stays
    // a sliver list because the grid size depends on the window bucket.
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = Theme.of(context).platform.isMobileUi
            ? 1
            : _crossAxisCount(constraints.windowSize);
        return AtriaListPage(
          title: Theme.of(context).platform.isMobileUi
              ? 'Items'
              : 'Products and services',
          subtitle: Theme.of(context).platform.isMobileUi
              ? 'Inventory & services'
              : null,
          actions: [
            AtriaHeaderIconAction(
              icon: Icons.assignment_outlined,
              tooltip: 'Stock summary',
              // `/stock` is a branch root and this screen lives in the items
              // branch: `push`ing it would render a second, shell-less copy on
              // the root navigator. `go` switches the branch.
              onPressed: () => context.go('/stock'),
            ),
            AtriaPrimaryAction(
              label: 'New item',
              onPressed: () => context.push('/items/new'),
            ),
          ],
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _statsRow(context, stats)),
              SliverToBoxAdapter(child: _searchRow(context, search, filter)),
              ..._itemSlivers(context, repo, visible, count),
            ],
          ),
        );
      },
    );
  }

  Widget _statsRow(BuildContext context, _StockStats stats) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, AppSpace.md, 0, AppSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: _StatCard(
              label: 'Stock value (sale)',
              icon: Icons.savings_outlined,
              value: MoneyText(
                stats.saleValue,
                compact: true,
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatCard(
              label: 'Low stock items',
              icon: Icons.warning_amber_rounded,
              value: Text(
                '${stats.lowCount}',
                style: text.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              onTap: stats.lowCount > 0
                  ? () => ref.read(_itemFilterProvider.notifier).state =
                        _ItemFilter.lowStock
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchRow(BuildContext context, String search, _ItemFilter filter) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Was a bare TextField; the shared field matches the other list
          // screens' search look and behavior.
          TransactionSearchField(
            controller: _searchController,
            hintText: 'Search name, SKU, HSN or barcode',
            onChanged: (value) =>
                ref.read(_itemSearchProvider.notifier).state = value,
            onClear: () {
              _searchController.clear();
              ref.read(_itemSearchProvider.notifier).state = '';
            },
          ),
          // The shared filter strip: a labelled select on a desktop window,
          // segmented pills on a phone — the same control every other list
          // screen uses, so the active filter always reads the same way.
          AtriaFilterBar(
            padding: const EdgeInsets.only(top: AppSpace.md),
            filters: [
              AtriaAdaptiveFilter<_ItemFilter>(
                label: 'Show',
                scrollable: false,
                value: filter,
                onChanged: (f) =>
                    ref.read(_itemFilterProvider.notifier).state = f,
                segments: [
                  for (final f in _ItemFilter.values)
                    AtriaSegment(
                      value: f,
                      label: _filterLabel(f),
                      icon: _filterIcon(f),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _itemSlivers(
    BuildContext context,
    ItemRepository? repo,
    AsyncValue<List<ItemEntity>> visible,
    int crossAxisCount,
  ) {
    if (repo == null) {
      return const [
        SliverFillRemaining(
          child: EmptyState(
            icon: Icons.business_center_outlined,
            title: 'No firm selected',
            message: 'Choose or create a firm to start managing items.',
          ),
        ),
      ];
    }

    final filtering =
        ref.watch(_itemSearchProvider).trim().isNotEmpty ||
        ref.watch(_itemFilterProvider) != _ItemFilter.all;

    return [
      visible.when(
        data: (items) => items.isEmpty
            ? SliverFillRemaining(
                child: EmptyState(
                  icon: filtering
                      ? Icons.search_off_rounded
                      : Icons.inventory_2_outlined,
                  title: filtering ? 'No matching items' : 'No items yet',
                  message: filtering
                      ? 'Try a different search term or clear the filters.'
                      : 'Add your first product or service to start billing.',
                  actionLabel: filtering ? null : 'Add Item',
                  onAction: filtering ? null : () => context.push('/items/new'),
                ),
              )
            : _itemsGrid(context, items, crossAxisCount),
        loading: () => const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, stackTrace) => SliverFillRemaining(
          child: EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not load items',
            message: error.toString(),
          ),
        ),
      ),
    ];
  }

  /// Rows of [crossAxisCount] cards each, top-aligned. NOT stretched: a
  /// sliver hands its rows unbounded height, and Row's CrossAxisAlignment
  /// .stretch forwards that infinity to the cards — first as a "BoxConstraints
  /// forces an infinite height" crash, and (replaced with IntrinsicHeight)
  /// as an infinite relayout loop that hangs the frame for over two minutes.
  /// Cards differ by a line or two at most, so alignment is invisible.
  Widget _itemsGrid(
    BuildContext context,
    List<ItemEntity> items,
    int crossAxisCount,
  ) {
    final rowCount = (items.length / crossAxisCount).ceil();
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 96),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, rowIndex) {
          final start = rowIndex * crossAxisCount;
          final end = (start + crossAxisCount).clamp(0, items.length);
          final rowItems = items.sublist(start, end);
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < rowItems.length; i++) ...[
                  Expanded(
                    child: _ItemTile(
                      item: rowItems[i],
                      onTap: () =>
                          context.push('/items/edit/${rowItems[i].id}'),
                      // Long-press duplicates: pre-fills the new-item form
                      // from this one — the fastest way to add a variant.
                      onLongPress: () =>
                          context.push('/items/new?from=${rowItems[i].id}'),
                      // Deleting used to require opening the editor and
                      // scrolling to the bottom of the page for a Danger Zone
                      // nobody reaches. Same confirm-and-soft-delete the editor
                      // performs, offered where the item is.
                      onDelete: () =>
                          _confirmDeleteFromList(context, ref, rowItems[i]),
                    ),
                  ),
                  if (i < crossAxisCount - 1) const SizedBox(width: 16),
                ],
                for (int i = rowItems.length; i < crossAxisCount; i++) ...[
                  const Expanded(child: SizedBox()),
                  if (i < crossAxisCount - 1) const SizedBox(width: 16),
                ],
              ],
            ),
          );
        }, childCount: rowCount),
      ),
    );
  }

  /// Deletes [item] after a confirmation, reusing the item editor's own copy
  /// and its soft-delete call so the two entry points cannot drift apart.
  Future<void> _confirmDeleteFromList(
    BuildContext context,
    WidgetRef ref,
    ItemEntity item,
  ) async {
    final repo = ref.read(itemRepositoryProvider);
    if (repo == null) return;
    // Captured before the dialog: the `await` is an async gap, and a
    // ScaffoldMessenger looked up afterwards can belong to a dead element.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete ${item.name}?',
      message:
          'This removes the item from your catalogue. Documents that '
          'already use it are not changed. You can restore it later from '
          'the recycle bin.',
    );
    if (confirmed != true) return;
    try {
      // ItemRepository.delete is a SOFT delete: it cannot fail with a
      // foreign-key error the way a hard delete would, which is why the copy
      // above promises a restore rather than a failure.
      await repo.delete(item.id);
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Item deleted — restore it from the recycle bin'),
        ),
      );
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not delete the item: $error')),
      );
    }
  }
}

/// One stat card from the summary pair at the top of the screen.
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.icon,
    required this.value,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final Widget value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: const BorderRadius.all(
                Radius.circular(AppRadius.sm),
              ),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: scheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                value,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.onDelete,
  });

  final ItemEntity item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Bins the item after a confirmation. Null hides the entry (create mode
  /// has nothing to bin).
  final Future<void> Function()? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final low = _isLowStock(item);
    final gstLabel =
        GstRate.fromDouble(item.gstRate)?.label ??
        Formatters.percent(item.gstRate);
    final unit = Unit.symbolOf(item.unit);

    if (Theme.of(context).platform.isMobileUi) {
      final stockLabel = item.isService
          ? 'Service'
          : item.stockType != 'tracked'
          ? 'Not tracked'
          : item.currentStock <= 0
          ? 'Out of stock'
          : '${Formatters.qty(Money.of(item.currentStock))} $unit in stock';
      return AtriaCard(
        onTap: onTap,
        onLongPress: onLongPress,
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
                    color: low
                        ? scheme.errorContainer
                        : scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    item.isService
                        ? Icons.design_services_outlined
                        : Icons.inventory_2_outlined,
                    size: 23,
                    color: low ? scheme.error : scheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if ((item.sku ?? '').isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          'SKU: ${item.sku}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color:
                        low ||
                            (!item.isService &&
                                item.stockType == 'tracked' &&
                                item.currentStock <= 0)
                        ? scheme.errorContainer
                        : scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Text(
                    stockLabel,
                    style: text.labelSmall?.copyWith(
                      color:
                          low ||
                              (!item.isService &&
                                  item.stockType == 'tracked' &&
                                  item.currentStock <= 0)
                          ? scheme.error
                          : scheme.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: scheme.outlineVariant),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.isService ? 'Rate' : 'Sale price',
                        style: text.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: MobileAmount(
                          Money.of(item.salePrice),
                          style: text.titleMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  'Details',
                  style: text.labelMedium?.copyWith(color: scheme.primary),
                ),
                Icon(Icons.chevron_right, size: 18, color: scheme.primary),
              ],
            ),
          ],
        ),
      );
    }
    return AtriaCard(
      onTap: onTap,
      onLongPress: onLongPress,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  item.name,
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: const BorderRadius.all(
                    Radius.circular(AppRadius.pill),
                  ),
                ),
                child: Text(
                  gstLabel,
                  style: text.labelSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              // Duplicate was reachable only by long-press — undiscoverable.
              // A visible menu puts it on the tile like every other list row,
              // and now carries Delete too, so binning an item no longer means
              // opening the editor and scrolling to a Danger Zone.
              PopupMenuButton<String>(
                tooltip: 'More actions',
                padding: EdgeInsets.zero,
                iconSize: 18,
                onSelected: (value) {
                  if (value == 'edit') {
                    onTap();
                  } else if (value == 'duplicate') {
                    onLongPress?.call();
                  } else if (value == 'delete') {
                    // The popup route is gone by the time this runs, so the
                    // future cannot be awaited here — the delete shows its own
                    // progress of its own (dialog + snackbar).
                    unawaited(onDelete?.call());
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('Edit'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'duplicate',
                    child: Row(
                      children: [
                        Icon(Icons.copy_rounded, size: 18),
                        SizedBox(width: 10),
                        Text('Duplicate'),
                      ],
                    ),
                  ),
                  if (onDelete != null)
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Delete',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _subtitle(item),
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MoneyText(
                Money.of(item.salePrice),
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 6),
              Text(
                'per $unit',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              if (low)
                const StatusChip(
                  label: 'Low',
                  kind: ChipKind.danger,
                  icon: Icons.warning_amber_rounded,
                )
              else if (item.stockType != 'tracked')
                const StatusChip(label: 'Untracked', kind: ChipKind.neutral)
              else
                Text(
                  '${Formatters.qty(Money.of(item.currentStock))} $unit',
                  style: text.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _subtitle(ItemEntity item) {
    final parts = <String>[];
    if ((item.sku ?? '').isNotEmpty) parts.add('SKU ${item.sku}');
    if ((item.hsn ?? '').isNotEmpty) parts.add('HSN ${item.hsn}');
    if (item.isService) {
      parts.add('Service');
    } else {
      parts.add(Unit.byId(item.unit)?.label ?? item.unit);
    }
    return parts.join(' · ');
  }
}
