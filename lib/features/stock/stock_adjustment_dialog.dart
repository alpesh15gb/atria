import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/report_repository.dart';
import '../../core/state/providers.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';

/// Result of a confirmed stock adjustment.
class StockAdjustmentInput {
  const StockAdjustmentInput({
    required this.itemId,
    required this.quantity,
    this.notes,
  });

  final String itemId;

  /// Signed delta: counted − current. Negative removes stock.
  final double quantity;
  final String? notes;
}

/// Ask the user for a physical count of [row]'s stock (or of a picked item
/// when [row] is null) and return the adjustment to post. Returns null when
/// the dialog is dismissed.
Future<StockAdjustmentInput?> showStockAdjustmentDialog(
  BuildContext context, {
  StockSummaryRow? row,
}) {
  return showDialog<StockAdjustmentInput>(
    context: context,
    builder: (_) => _StockAdjustmentDialog(initial: row),
  );
}

class _StockAdjustmentDialog extends ConsumerStatefulWidget {
  const _StockAdjustmentDialog({this.initial});

  final StockSummaryRow? initial;

  @override
  ConsumerState<_StockAdjustmentDialog> createState() =>
      _StockAdjustmentDialogState();
}

class _StockAdjustmentDialogState
    extends ConsumerState<_StockAdjustmentDialog> {
  final _countController = TextEditingController();
  final _notesController = TextEditingController();
  List<ItemEntity> _items = const [];
  ItemEntity? _selected;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _countController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(itemRepositoryProvider);
    final items = await repo?.all() ?? const <ItemEntity>[];
    final tracked = items.where((i) => i.stockType == 'tracked').toList();
    if (!mounted) return;
    setState(() {
      _items = tracked;
      if (widget.initial != null) {
        _selected = tracked
            .where((i) => i.id == widget.initial!.itemId)
            .cast<ItemEntity?>()
            .firstWhere((i) => i?.id == widget.initial!.itemId,
                orElse: () => null);
        _countController.text = _qty(widget.initial!.stock);
      }
      _loading = false;
    });
  }

  String _qty(double value) => Formatters.qty(Money.of(value));

  double get _currentStock {
    final selected = _selected;
    if (selected == null) return 0;
    if (widget.initial != null && widget.initial!.itemId == selected.id) {
      return widget.initial!.stock;
    }
    return selected.currentStock;
  }

  double? get _delta {
    final counted = double.tryParse(_countController.text.trim());
    if (counted == null) return null;
    return counted - _currentStock;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final delta = _delta;
    final canSave = _selected != null && delta != null && delta != 0 && !_saving;

    return AlertDialog(
      title: const Text('Adjust stock'),
      content: _loading
          ? const SizedBox(
              width: 320,
              height: 80,
              child: Center(child: CircularProgressIndicator()),
            )
          : SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<ItemEntity>(
                    initialValue: _selected,
                    decoration: const InputDecoration(
                      labelText: 'Item',
                      prefixIcon: Icon(Icons.inventory_2_outlined),
                    ),
                    items: [
                      for (final item in _items)
                        DropdownMenuItem(
                          value: item,
                          child: Text(item.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (item) {
                            setState(() {
                              _selected = item;
                              if (item != null) {
                                _countController.text = _qty(item.currentStock);
                              }
                            });
                          },
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _countController,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                            labelText: 'Counted quantity',
                            helperText:
                                'System says ${_qty(_currentStock)} — enter what you actually have',
                            // Save used to grey out with no reason when the
                            // text wasn't a number (grouped digits, stray
                            // spaces) — now the field says what's wrong.
                            errorText: _countController.text.trim().isEmpty ||
                                    delta != null
                                ? null
                                : 'Enter a number, e.g. 12 or 12.5',
                            prefixIcon:
                                const Icon(Icons.straighten_rounded),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    delta == null
                        ? ' '
                        : (delta > 0
                            ? 'Will add ${_qty(delta)} to stock'
                            : 'Will remove ${_qty(-delta)} from stock'),
                    style: text.bodySmall?.copyWith(
                      color: delta == null || delta == 0
                          ? scheme.onSurfaceVariant
                          : (delta > 0 ? scheme.primary : scheme.error),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _notesController,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Reason (optional)',
                      hintText: 'e.g. damaged, theft, recount',
                      prefixIcon: Icon(Icons.notes_rounded),
                    ),
                  ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canSave
              ? () {
                  setState(() => _saving = true);
                  Navigator.of(context).pop(StockAdjustmentInput(
                    itemId: _selected!.id,
                    quantity: _delta!,
                    notes: _notesController.text.trim().isEmpty
                        ? null
                        : _notesController.text.trim(),
                  ));
                }
              : null,
          child: const Text('Post adjustment'),
        ),
      ],
    );
  }
}
