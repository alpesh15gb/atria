import 'package:flutter/material.dart';

import '../../core/constants/units.dart';

/// A type-ahead item picker for document lines (sale + purchase editors).
///
/// Vyapar-style contract (the pattern QuickBooks/Zoho share):
///  * typing filters the catalogue as you type;
///  * typing a name that does NOT match anything is still accepted — on
///    commit (Enter / focus loss / "Save item" row) [onCreateItem] fires so
///    the host can persist it silently: no dialog, no second step;
///  * picking a suggestion lets the host fill rate/unit/GST via [onPickItem].
///
/// Binds to a HOST-OWNED [controller] (the line's name controller) so editor
/// re-renders — live item feeds, totals recalc — never clobber typing.
class ItemTypeAheadField extends StatefulWidget {
  const ItemTypeAheadField({
    super.key,
    required this.controller,
    required this.items,
    required this.onPickItem,
    required this.onCreateItem,
    this.label = 'Item',
    this.hintText = 'Type an item name — new names are saved automatically',
  });

  /// The line's name controller. Kept in sync with line state by the host.
  final TextEditingController controller;

  /// Full catalogue; filtered here as the user types.
  final List<ItemSuggestion> items;

  /// A catalogue item was selected from the dropdown.
  final ValueChanged<ItemSuggestion> onPickItem;

  /// The typed name matches nothing in [items] and the user committed it
  /// (Enter / focus loss / picking the "Save item" row). Fires once per
  /// commit; the host persists the item and links the line to it.
  final ValueChanged<String> onCreateItem;

  final String label;
  final String hintText;

  @override
  State<ItemTypeAheadField> createState() => _ItemTypeAheadFieldState();
}

class _ItemTypeAheadFieldState extends State<ItemTypeAheadField> {
  final _focus = FocusNode();

  /// Guards double-fires: Enter on the highlighted suggestion ALSO submits
  /// the field (RawAutocomplete fires onSelected and onSubmitted for the
  /// same keypress), and focus loss can fire again afterwards. Compared
  /// case-insensitively so the "Save item" row (built from the query) and
  /// the raw field text cannot slip past each other.
  String _lastCommitted = '';

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusLost);
  }

  void _onFocusLost() {
    if (_focus.hasFocus) return;
    _commitFreeText(widget.controller.text);
  }

  /// If [value] matches nothing in the catalogue, treat it as a new item.
  void _commitFreeText(String value) {
    final name = value.trim();
    if (name.isEmpty) return;
    if (_alreadyCommitted(name)) return;
    final exists = widget.items.any(
      (i) => i.name.toLowerCase() == name.toLowerCase(),
    );
    if (exists) return;
    _lastCommitted = name;
    widget.onCreateItem(name);
  }

  bool _alreadyCommitted(String name) =>
      name.toLowerCase() == _lastCommitted.toLowerCase();

  @override
  void dispose() {
    _focus.removeListener(_onFocusLost);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RawAutocomplete<ItemSuggestion>(
      textEditingController: widget.controller,
      focusNode: _focus,
      displayStringForOption: (o) => o.name,
      optionsBuilder: (value) {
        final query = value.text.trim().toLowerCase();
        if (query.isEmpty) return const Iterable<ItemSuggestion>.empty();
        final matches = widget.items
            .where((i) => i.name.toLowerCase().contains(query))
            .toList(growable: false);
        // The "Save item" row leads whenever the exact name is absent, so
        // accepting a brand-new name is one Enter away.
        final exact = matches.any((m) => m.name.toLowerCase() == query);
        return [
          // Preserve the user's casing — this name becomes the item's name.
          if (!exact && value.text.trim().isNotEmpty)
            ItemSuggestion(
                name: value.text.trim(), salePrice: 0, isNew: true),
          ...matches,
        ];
      },
      fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hintText,
            isDense: true,
            prefixIcon: const Icon(Icons.inventory_2_outlined, size: 19),
          ),
          onSubmitted: (_) {
            _commitFreeText(controller.text);
            onSubmitted();
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(10),
            color: scheme.surface,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260, maxWidth: 420),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final o = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    // RawAutocomplete only HANDS you onSelected — wiring it
                    // to the row is this builder's job. Without onTap, mouse
                    // taps on suggestions did nothing at all.
                    onTap: () => onSelected(o),
                    leading: Icon(
                      o.isNew
                          ? Icons.add_circle_outline_rounded
                          : Icons.inventory_2_outlined,
                      size: 19,
                      color: o.isNew ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    title: Text(
                      o.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: o.isNew
                        ? Text(
                            'Save item',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: scheme.primary),
                          )
                        : Text(
                            o.salePrice > 0
                                ? '₹${o.salePrice.toStringAsFixed(0)}'
                                    ' · ${Unit.symbolOf(o.unit)}'
                                : Unit.symbolOf(o.unit),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                          ),
                  );
                },
              ),
            ),
          ),
        );
      },
      onSelected: (option) {
        if (option.isNew) {
          if (_alreadyCommitted(option.name)) return;
          _lastCommitted = option.name;
          widget.onCreateItem(option.name);
          return;
        }
        _lastCommitted = option.name;
        widget.onPickItem(option);
      },
    );
  }
}

/// One row in the type-ahead dropdown.
class ItemSuggestion {
  const ItemSuggestion({
    required this.name,
    required this.salePrice,
    this.unit = 'pcs',
    this.isNew = false,
  });

  final String name;
  final double salePrice;
  final String unit;
  final bool isNew;
}
