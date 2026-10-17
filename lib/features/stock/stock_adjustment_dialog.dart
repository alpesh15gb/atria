import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/report_repository.dart';
import '../../core/state/providers.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/atria_field_icon.dart';
import '../../shared/widgets/item_type_ahead.dart';

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
  final _itemController = TextEditingController();
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
    _itemController.dispose();
    _countController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(itemRepositoryProvider);
    // limit: 0 = every row. The picker used to be a DropdownButtonFormField fed
    // by `repo.all()`'s DEFAULT cap of 1000 with no search, so on a catalogue
    // past a thousand items the item being counted simply could not be chosen
    // — and the stock screen lists every tracked item, so this dialog is how
    // each of them is adjusted.
    final items = await repo?.all(limit: 0) ?? const <ItemEntity>[];
    final tracked = items.where((i) => i.stockType == 'tracked').toList();
    if (!mounted) return;
    setState(() {
      _items = tracked;
      if (widget.initial != null) {
        final found = tracked
            .where((i) => i.id == widget.initial!.itemId)
            .cast<ItemEntity?>()
            .firstWhere((i) => i != null, orElse: () => null);
        _selected = found;
        if (found != null) _itemController.text = found.name;
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

  /// What the user typed into "Counted quantity", or null when it is not a
  /// number.
  double? get _counted => double.tryParse(_countController.text.trim());

  /// A physical count is a count: it cannot be below zero.
  ///
  /// This dialog posts a DELTA (`counted - current`), so `-12` against a current
  /// 40 silently booked a removal of 52 — stock the shop says it does not have,
  /// written to the ledger with no warning. Rejected inline instead.
  bool get _countNegative => (_counted ?? 0) < 0 && _counted != null;

  /// Signed adjustment, or null when there is nothing sensible to post.
  double? get _delta {
    final counted = _counted;
    if (counted == null || counted < 0) return null;
    return counted - _currentStock;
  }

  void _select(ItemEntity item) {
    setState(() {
      _selected = item;
      _itemController.text = item.name;
      _countController.text = _qty(item.currentStock);
    });
  }

  /// The searchable item field.
  ///
  /// The stock type-ahead, not a dropdown: this is the app's own line-item
  /// picker, so the search matches name, SKU, HSN and barcode the way every
  /// other picker in the app does, and it shows a price and unit per suggestion.
  /// `allowCreate: false` is essential — adjusting stock must never invent a
  /// product, so there is no "Save item" row and nothing here can write to the
  /// catalogue.
  Widget _itemField() {
    return ItemTypeAheadField(
      controller: _itemController,
      label: 'Item *',
      hintText: 'Type a name, SKU or barcode to search',
      allowCreate: false,
      items: [
        for (final item in _items)
          ItemSuggestion(
            id: item.id,
            name: item.name,
            salePrice: item.salePrice,
            unit: item.unit,
            sku: item.sku,
            hsn: item.hsn,
            barcode: item.barcode,
          ),
      ],
      onPickItem: (suggestion) {
        // By id, not by name equality: two items differing only by case would
        // otherwise resolve to whichever came first in the catalogue.
        final id = suggestion.id;
        if (id == null) return;
        final match = _items
            .where((i) => i.id == id)
            .cast<ItemEntity?>()
            .firstWhere((i) => i != null, orElse: () => null);
        if (match != null) _select(match);
      },
      // Unreachable with allowCreate: false; present because the widget's
      // contract requires a handler.
      onCreateItem: (_) {},
      decoration: (context) => InputDecoration(
        labelText: 'Item *',
        hintText: 'Type a name, SKU or barcode to search',
        prefixIcon: const AtriaFieldIcon(Icons.inventory_2_outlined),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final delta = _delta;
    final canSave = _selected != null &&
        delta != null &&
        delta != 0 &&
        !_countNegative &&
        !_saving;

    return AlertDialog(
      title: const Text('Adjust stock'),
      content: _loading
          ? const SizedBox(
              width: 320,
              height: 80,
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _itemField(),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _countController,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Counted quantity',
                      helperText: _selected == null
                          ? 'Pick an item first'
                          : 'System says ${_qty(_currentStock)} — enter what '
                              'you actually have',
                      // Save used to grey out with no reason when the text
                      // wasn't a number (grouped digits, stray spaces) — now the
                      // field says what's wrong. A negative count gets the same
                      // treatment as an unparseable one: it cannot be posted.
                      errorText: _countNegative
                          ? 'A counted quantity cannot be negative'
                          : _countController.text.trim().isEmpty || delta != null
                              ? null
                              : 'Enter a number, e.g. 12 or 12.5',
                      prefixIcon: const AtriaFieldIcon(Icons.straighten_rounded),
                    ),
                    onChanged: (_) => setState(() {}),
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
                      prefixIcon: AtriaFieldIcon(Icons.notes_rounded),
                    ),
                  ),
                ],
              ),
            )),
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
