import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/gst.dart';
import '../../core/constants/units.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/item_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/status_chip.dart';
import '../../shared/widgets/transaction_list.dart';

enum _ItemFilter { all, lowStock, services }

final _itemFilterProvider = StateProvider<_ItemFilter>(
  (ref) => _ItemFilter.all,
);
final _itemSearchProvider = StateProvider<String>((ref) => '');

final _allItemsProvider = StreamProvider<List<ItemEntity>>((ref) {
  final repo = ref.watch(itemRepositoryProvider);
  if (repo == null) return Stream.value(const <ItemEntity>[]);
  return repo.watchAll();
});

/// Search and chip filtering applied on top of [_allItemsProvider].
final _visibleItemsProvider = Provider<AsyncValue<List<ItemEntity>>>((ref) {
  final filter = ref.watch(_itemFilterProvider);
  final search = ref.watch(_itemSearchProvider).trim().toLowerCase();
  return ref
      .watch(_allItemsProvider)
      .whenData((items) => _applyFilter(items, filter, search));
});

List<ItemEntity> _applyFilter(
  List<ItemEntity> items,
  _ItemFilter filter,
  String search,
) {
  var out = items;
  if (search.isNotEmpty) {
    out = items
        .where(
          (item) =>
              item.name.toLowerCase().contains(search) ||
              (item.sku ?? '').toLowerCase().contains(search) ||
              (item.hsn ?? '').toLowerCase().contains(search) ||
              (item.barcode ?? '').toLowerCase().contains(search),
        )
        .toList(growable: false);
  }
  switch (filter) {
    case _ItemFilter.lowStock:
      return out.where(_isLowStock).toList(growable: false);
    case _ItemFilter.services:
      return out.where((item) => item.isService).toList(growable: false);
    case _ItemFilter.all:
      return out;
  }
}

bool _isLowStock(ItemEntity item) =>
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
    if (item.stockType != 'tracked') continue;
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Items'),
        actions: [
          IconButton(
            icon: const Icon(Icons.assignment_outlined),
            tooltip: 'Stock summary',
            onPressed: () => context.push('/stock'),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final count = _crossAxisCount(constraints.windowSize);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _statsRow(context, stats)),
              SliverToBoxAdapter(child: _searchRow(context, search, filter)),
              ..._itemSlivers(context, repo, visible, count),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Item'),
        onPressed: () => context.push('/items/new'),
      ),
    );
  }

  Widget _statsRow(BuildContext context, _StockStats stats) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
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
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in _ItemFilter.values)
                FilterChip(
                  label: Text(_filterLabel(f)),
                  avatar: Icon(_filterIcon(f), size: 16),
                  selected: filter == f,
                  onSelected: (_) =>
                      ref.read(_itemFilterProvider.notifier).state = f,
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
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
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
                    ),
                  ),
                  if (i < rowItems.length - 1) const SizedBox(width: 16),
                ],
              ],
            ),
          );
        }, childCount: rowCount),
      ),
    );
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
  const _ItemTile({required this.item, required this.onTap, this.onLongPress});

  final ItemEntity item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final low = _isLowStock(item);
    final gstLabel =
        GstRate.fromDouble(item.gstRate)?.label ??
        Formatters.percent(item.gstRate);
    final unit = Unit.symbolOf(item.unit);

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
              // A visible menu puts it on the tile like every other list row.
              PopupMenuButton<String>(
                tooltip: 'More actions',
                padding: EdgeInsets.zero,
                iconSize: 18,
                onSelected: (value) {
                  if (value == 'edit') {
                    onTap();
                  } else if (value == 'duplicate') {
                    onLongPress?.call();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                      value: 'edit',
                      child: Row(children: [
                        Icon(Icons.edit_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('Edit'),
                      ])),
                  PopupMenuItem(
                      value: 'duplicate',
                      child: Row(children: [
                        Icon(Icons.copy_rounded, size: 18),
                        SizedBox(width: 10),
                        Text('Duplicate'),
                      ])),
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
