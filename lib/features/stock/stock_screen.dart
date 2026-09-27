import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/units.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/report_repository.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import 'stock_adjustment_dialog.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/status_chip.dart';

final _stockSummaryProvider = FutureProvider<List<StockSummaryRow>>((ref) async {
  final repo = ref.watch(reportRepositoryProvider);
  if (repo == null) return const <StockSummaryRow>[];
  return repo.stockSummary();
});

class _Totals {
  const _Totals({
    required this.count,
    required this.qty,
    required this.saleValue,
    required this.purchaseValue,
    required this.lowCount,
  });

  final int count;
  final Decimal qty;
  final Decimal saleValue;
  final Decimal purchaseValue;
  final int lowCount;
}

_Totals _computeTotals(List<StockSummaryRow> rows) {
  var qty = Decimal.zero;
  var sale = Decimal.zero;
  var purchase = Decimal.zero;
  var low = 0;
  for (final row in rows) {
    qty += Money.of(row.stock);
    sale += row.saleValue;
    purchase += row.purchaseValue;
    if (row.isLow) low++;
  }
  return _Totals(
    count: rows.length,
    qty: qty,
    saleValue: sale,
    purchaseValue: purchase,
    lowCount: low,
  );
}

String _movementKindLabel(String kind) => switch (kind) {
      'opening' => 'Opening balance',
      'sale' => 'Sale',
      'purchase' => 'Purchase',
      'sale_return' => 'Sale return',
      'purchase_return' => 'Purchase return',
      'adjustment' => 'Stock adjustment',
      _ => kind,
    };

IconData _movementKindIcon(String kind) => switch (kind) {
      'opening' => Icons.play_circle_outline_rounded,
      'sale' => Icons.south_east_rounded,
      'purchase' => Icons.north_east_rounded,
      'sale_return' => Icons.undo_rounded,
      'purchase_return' => Icons.redo_rounded,
      'adjustment' => Icons.tune_rounded,
      _ => Icons.swap_vert_rounded,
    };

class StockScreen extends ConsumerStatefulWidget {
  const StockScreen({super.key});

  @override
  ConsumerState<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends ConsumerState<StockScreen> {
  bool _lowOnly = false;

  /// Opens the stock-adjustment dialog for [row] (or, with [row] null, lets
  /// the user pick any tracked item). On success the summary re-reads and the
  /// movement history gains the adjustment row.
  Future<void> _adjustStock([StockSummaryRow? row]) async {
    final itemRepo = ref.read(itemRepositoryProvider);
    if (itemRepo == null) return;
    final saved = await showStockAdjustmentDialog(context, row: row);
    if (saved == null || !mounted) return;
    try {
      await itemRepo.applyStockEffect(
        itemId: saved.itemId,
        quantity: saved.quantity,
        kind: 'adjustment',
        source: 'adjustment',
        notes: saved.notes,
      );
    } catch (e) {
      // The adjustment dialog had already closed: a failed write vanished
      // without a trace and the counts never updated.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not adjust stock: $e')),
      );
      return;
    }
    if (!mounted) return;
    ref.invalidate(_stockSummaryProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Stock adjusted')),
    );
  }

  Future<void> _showMovements(StockSummaryRow row) async {
    final itemRepo = ref.read(itemRepositoryProvider);
    var movements = const <StockMovementEntity>[];
    if (itemRepo != null) {
      movements = await itemRepo.movements(row.itemId);
    }
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final text = Theme.of(sheetContext).textTheme;
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              row.name,
                              style: text.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Current stock: '
                              '${Formatters.qty(Money.of(row.stock))} '
                              '${Unit.symbolOf(row.unit)}',
                              style: text.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (row.isLow)
                        const StatusChip(
                          label: 'Low',
                          kind: ChipKind.danger,
                          icon: Icons.warning_amber_rounded,
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: movements.isEmpty
                      ? const EmptyState(
                          icon: Icons.swap_vert_rounded,
                          title: 'No movements yet',
                          message: 'Sales, purchases and adjustments will '
                              'show up here with their running balance.',
                          compact: true,
                        )
                      : ListView.separated(
                          itemCount: movements.length,
                          padding: const EdgeInsets.only(bottom: 12),
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) =>
                              _MovementTile(movement: movements[index]),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(reportRepositoryProvider);
    final asyncRows = ref.watch(_stockSummaryProvider);
    final all = asyncRows.valueOrNull ?? const <StockSummaryRow>[];
    final rows = _lowOnly
        ? all.where((row) => row.isLow).toList(growable: false)
        : all;
    // Totals describe the rows actually listed; computing them from `all` made
    // the cards disagree with the table whenever the low-stock filter was on.
    final totals = _computeTotals(rows);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock Summary'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Adjust stock',
            onPressed: repo == null ? null : () => _adjustStock(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(_stockSummaryProvider),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _summaryCards(context, totals, repo == null)),
              SliverToBoxAdapter(child: _filterRow()),
              if (repo == null)
                const SliverFillRemaining(
                  child: EmptyState(
                    icon: Icons.business_center_outlined,
                    title: 'No firm selected',
                    message: 'Choose or create a firm to view stock reports.',
                  ),
                )
              else if (asyncRows.isLoading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (rows.isEmpty)
                SliverFillRemaining(
                  child: EmptyState(
                    icon: _lowOnly
                        ? Icons.check_circle_outline_rounded
                        : Icons.inventory_2_outlined,
                    title: _lowOnly ? 'No low-stock items' : 'No tracked items',
                    message: _lowOnly
                        ? 'Every tracked item is above its alert level.'
                        : 'Create stock-tracked items to see their valuation '
                            'and movement history here.',
                  ),
                )
              else
                SliverToBoxAdapter(
                  child: _table(context, constraints.maxWidth, rows, totals),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _summaryCards(BuildContext context, _Totals totals, bool noFirm) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: _StatCard(
              label: 'Tracked items',
              icon: Icons.inventory_2_outlined,
              value: Text(
                noFirm ? '-' : '${totals.count}',
                style: text.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatCard(
              label: 'Stock at sale',
              icon: Icons.savings_outlined,
              value: MoneyText(
                totals.saleValue,
                compact: true,
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatCard(
              label: 'Low stock',
              icon: Icons.warning_amber_rounded,
              value: Text(
                noFirm ? '-' : '${totals.lowCount}',
                style: text.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: totals.lowCount > 0
                      ? atriaColors(context).danger
                      : null,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              onTap: totals.lowCount > 0
                  ? () => setState(() => _lowOnly = true)
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FilterChip(
          label: const Text('Low stock only'),
          avatar: const Icon(Icons.warning_amber_rounded, size: 16),
          selected: _lowOnly,
          onSelected: (selected) => setState(() => _lowOnly = selected),
        ),
      ),
    );
  }

  Widget _table(
    BuildContext context,
    double availableWidth,
    List<StockSummaryRow> rows,
    _Totals totals,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final minWidth = availableWidth < 760.0 ? 760.0 : availableWidth;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: AppRadius.lgAll,
          border: Border.all(color: scheme.outline, width: 0.9),
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // A tight width, not ConstrainedBox(minWidth): the scroll view hands
          // its child UNBOUNDED width, and the Column's CrossAxisAlignment
          // .stretch forwards that infinity into the Expanded table rows —
          // the same crash class that blanked the Items grid. SizedBox pins
          // the intended content width so stretch is bounded and horizontal
          // scrolling still engages on narrow panes.
          child: SizedBox(
            width: minWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _headerRow(context),
                for (final row in rows) _dataRow(context, row),
                _totalsRow(context, totals),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const List<int> _flexes = [4, 2, 1, 2, 1, 2, 2];
  static const List<String> _headers = [
    'Item',
    'HSN/SAC',
    'Unit',
    'Qty',
    'GST',
    'Sale value',
    'Cost value',
  ];

  Widget _headerRow(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          for (int i = 0; i < _headers.length; i++)
            Expanded(
              flex: _flexes[i],
              child: Align(
                alignment:
                    i >= 3 ? Alignment.centerRight : Alignment.centerLeft,
                child: Text(
                  _headers[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _dataRow(BuildContext context, StockSummaryRow row) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final valueStyle = text.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final mutedStyle =
        text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    return Material(
      color: scheme.surface,
      child: InkWell(
        onTap: () => _showMovements(row),
        onLongPress: () => _adjustStock(row),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: scheme.outlineVariant, width: 0.8),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: _flexes[0],
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        row.name,
                        style: valueStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (row.isLow) ...[
                      const SizedBox(width: 8),
                      const StatusChip(
                        label: 'Low',
                        kind: ChipKind.danger,
                        icon: Icons.warning_amber_rounded,
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                flex: _flexes[1],
                child: Text(
                  row.hsn ?? '-',
                  style: mutedStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Expanded(
                flex: _flexes[2],
                child: Text(Unit.symbolOf(row.unit), style: mutedStyle),
              ),
              Expanded(
                flex: _flexes[3],
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    Formatters.qty(Money.of(row.stock)),
                    style: valueStyle?.copyWith(
                      color: row.isLow ? atriaColors(context).danger : null,
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: _flexes[4],
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(Formatters.percent(row.gstRate), style: mutedStyle),
                ),
              ),
              Expanded(
                flex: _flexes[5],
                child: Align(
                  alignment: Alignment.centerRight,
                  child: MoneyText(
                    row.saleValue,
                    compact: true,
                    style: valueStyle,
                  ),
                ),
              ),
              Expanded(
                flex: _flexes[6],
                child: Align(
                  alignment: Alignment.centerRight,
                  child: MoneyText(
                    row.purchaseValue,
                    compact: true,
                    style: mutedStyle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _totalsRow(BuildContext context, _Totals totals) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final style = text.titleSmall?.copyWith(
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: _flexes[0],
            child: Text('Total · ${totals.count} items', style: style),
          ),
          Expanded(flex: _flexes[1], child: const SizedBox()),
          Expanded(flex: _flexes[2], child: const SizedBox()),
          Expanded(
            flex: _flexes[3],
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(Formatters.qty(totals.qty), style: style),
            ),
          ),
          Expanded(flex: _flexes[4], child: const SizedBox()),
          Expanded(
            flex: _flexes[5],
            child: Align(
              alignment: Alignment.centerRight,
              child: MoneyText(
                totals.saleValue,
                compact: true,
                style: style,
              ),
            ),
          ),
          Expanded(
            flex: _flexes[6],
            child: Align(
              alignment: Alignment.centerRight,
              child: MoneyText(
                totals.purchaseValue,
                compact: true,
                style: style,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius:
                  const BorderRadius.all(Radius.circular(AppRadius.sm)),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: scheme.primary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
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

class _MovementTile extends StatelessWidget {
  const _MovementTile({required this.movement});

  final StockMovementEntity movement;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final colors = atriaColors(context);
    final qty = Money.of(movement.quantity);
    final positive = qty >= Decimal.zero;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: positive ? colors.successSurface : colors.dangerSurface,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.sm)),
        ),
        alignment: Alignment.center,
        child: Icon(
          _movementKindIcon(movement.kind),
          size: 17,
          color: positive ? colors.onSuccessSurface : colors.onDangerSurface,
        ),
      ),
      title: Text(
        _movementKindLabel(movement.kind),
        style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        (movement.sourceNumber == null || movement.sourceNumber!.isEmpty)
            ? Formatters.dateTime(movement.date)
            : '${Formatters.dateTime(movement.date)} · '
                '${movement.sourceNumber}',
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${positive ? '+' : ''}${Formatters.qty(qty)}',
            style: text.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: positive ? colors.positive : colors.negative,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            'Bal ${Formatters.qty(Money.of(movement.balanceAfter))}',
            style: text.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
