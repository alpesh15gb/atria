import 'package:flutter/material.dart';

import '../../core/constants/units.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/atria_field_icon.dart';

/// A type-ahead item picker for document lines (sale + purchase editors).
///
/// Vyapar-style contract (the pattern QuickBooks/Zoho share):
///  * typing filters the catalogue as you type — by NAME, SKU, HSN or barcode,
///    whichever the shop actually has to hand (see [itemSuggestionMatches]);
///  * a full identifier that some row already claims resolves to that row and
///    NEVER offers to create a new item, so a scanned barcode cannot become an
///    item named after the code;
///  * typing a value that matches nothing is still accepted — on commit
///    (Enter / focus loss / "Save item" row) [onCreateItem] fires so the host
///    can persist it silently: no dialog, no second step;
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
    this.focusNode,
    this.validator,
    this.decoration,
    this.allowCreate = true,
  });

  /// The line's name controller. Kept in sync with line state by the host.
  final TextEditingController controller;

  /// Full catalogue; filtered here as the user types.
  ///
  /// Populate `sku` / `hsn` / `barcode` on each row — without them the match
  /// degrades to name-only and a scanned code stops resolving.
  final List<ItemSuggestion> items;

  /// A catalogue item was selected from the dropdown.
  final ValueChanged<ItemSuggestion> onPickItem;

  /// The typed value matches nothing in [items] by name, SKU, HSN or barcode
  /// and the user committed it (Enter / focus loss / picking the "Save item"
  /// row). Fires once per commit; the host persists the item and links the
  /// line to it.
  final ValueChanged<String> onCreateItem;

  final String label;
  final String hintText;

  /// Optional externally-owned focus node, so an editor can move focus to a
  /// freshly added line's item cell (the Enter-to-add-a-row flow).
  final FocusNode? focusNode;

  /// Optional validation, for callers that render this as a form cell.
  final String? Function(String?)? validator;

  /// Full decoration override — the line grid's cell builds one.
  ///
  /// A builder, not a decoration: the grid's cell changes shape between the
  /// desktop sheet (borderless) and the stacked card (boxed), and the field
  /// is constructed above the grid, so it can only ask once it is building
  /// inside it.
  final InputDecoration? Function(BuildContext context)? decoration;

  /// Whether an unmatched value may become a new catalogue item.
  ///
  /// False for a picker that must select an EXISTING row and must never invent
  /// one — the stock-adjustment dialog, where "Save item" would be a promise the
  /// dialog cannot keep. The dropdown then offers matches only, and
  /// [onCreateItem] is never called.
  final bool allowCreate;

  @override
  State<ItemTypeAheadField> createState() => _ItemTypeAheadFieldState();
}

class _ItemTypeAheadFieldState extends State<ItemTypeAheadField> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();

  /// Only a node this widget made may be disposed here.
  bool get _ownsFocus => widget.focusNode == null;

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
  ///
  /// The test is the SAME combined identifier match the dropdown uses (see
  /// [itemSuggestionMatches]). It was name-equality only, so a barcode typed or
  /// scanned into a line matched nothing here and fell through to
  /// [onCreateItem] — creating a real catalogue item literally named
  /// "8901234567890" beside the product the code actually belongs to.
  void _commitFreeText(String value) {
    final name = value.trim();
    if (name.isEmpty) return;
    if (_alreadyCommitted(name)) return;
    if (!widget.allowCreate) return;
    if (widget.items.any((i) => itemSuggestionMatches(i, name))) return;
    _lastCommitted = name;
    widget.onCreateItem(name);
  }

  bool _alreadyCommitted(String name) =>
      name.toLowerCase() == _lastCommitted.toLowerCase();

  @override
  void dispose() {
    _focus.removeListener(_onFocusLost);
    if (_ownsFocus) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = _field(Theme.of(context).colorScheme);
    final validator = widget.validator;
    if (validator == null) return field;
    // A plain TextField cannot carry a validator, so the grid's item cell
    // wraps the type-ahead in a FormField: an empty line then blocks Save
    // with an inline "Required" instead of the line silently vanishing.
    return FormField<String>(
      validator: (_) => validator(widget.controller.text),
      builder: (state) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          field,
          if (state.hasError)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 8),
              child: Text(
                state.errorText!,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _field(ColorScheme scheme) {
    return RawAutocomplete<ItemSuggestion>(
      textEditingController: widget.controller,
      focusNode: _focus,
      displayStringForOption: (o) => o.name,
      optionsBuilder: (value) {
        final raw = value.text.trim();
        final query = raw.toLowerCase();
        if (query.isEmpty) return const Iterable<ItemSuggestion>.empty();
        // Two buckets, because a barcode scanner types a WHOLE code and
        // presses Enter, and RawAutocomplete highlights index 0 — the product
        // the code belongs to has to be the row under the finger. This mirrors
        // the order `pos_screen._submitSearch` uses: exact code first, then
        // name matches.
        final exact = <ItemSuggestion>[];
        final partial = <ItemSuggestion>[];
        for (final item in widget.items) {
          if (itemSuggestionExactMatch(item, raw)) {
            exact.add(item);
          } else if (itemSuggestionMatches(item, raw)) {
            partial.add(item);
          }
        }
        return [
          ...exact,
          ...partial,
          // The create row leads only when NO existing item claims this value
          // by name, SKU, HSN or barcode — the exact test, not a substring one.
          // It used to lead whenever the exact NAME was absent, so scanning an
          // EAN-13 offered "Save item" above the product it identifies and put
          // a junk row in the catalogue.
          if (widget.allowCreate && exact.isEmpty && raw.isNotEmpty)
            // Preserve the user's casing — this name becomes the item's name.
            ItemSuggestion(name: raw, salePrice: 0, isNew: true),
        ];
      },
      fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.words,
          decoration:
              widget.decoration?.call(context) ??
              InputDecoration(
                labelText: widget.label,
                hintText: widget.hintText,
                isDense: true,
                prefixIcon: const AtriaFieldIcon(Icons.inventory_2_outlined, size: 18),
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
            // The app's floating-panel surface (see [AppTheme.menuShape]): a
            // hairline card with a soft lift. Elevation alone leaves this
            // panel edgeless where the page under it is white as well.
            color: scheme.surface,
            elevation: AppTheme.menuElevation,
            surfaceTintColor: Colors.transparent,
            shape: AppTheme.menuShape(scheme),
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
                      size: 18,
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
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: scheme.primary),
                          )
                        : Text(
                            o.salePrice > 0
                                ? '₹${o.salePrice.toStringAsFixed(0)}'
                                      ' · ${Unit.symbolOf(o.unit)}'
                                : Unit.symbolOf(o.unit),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
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
    this.sku,
    this.hsn,
    this.barcode,
    this.id,
  });

  final String name;
  final double salePrice;
  final String unit;
  final bool isNew;

  /// The catalogue row this suggestion came from, when the host has one.
  ///
  /// Present so a host can resolve a pick by identity instead of by name
  /// equality — two items differing only by case or by trailing text are
  /// otherwise indistinguishable and the first always wins.
  final String? id;

  /// The other three ways a shop identifies a product. Optional so existing
  /// hosts keep compiling, but a host that leaves them null gets name-only
  /// matching — the bug A10 was: a scanned EAN-13 then matched nothing and
  /// became a new item called "8901234567890". Pass `sku`, `hsn` and `barcode`
  /// from the catalogue row alongside the name.
  final String? sku;
  final String? hsn;
  final String? barcode;
}

/// Does [item] match the raw text the user typed or scanned into a line cell?
///
/// Four identifiers, because a shop enters all four: name (typed), SKU (read
/// off the box), HSN/SAC (read off the label) and barcode (scanned). Matching
/// on the name alone is what let a scanned code miss the product it belongs to.
///
/// The barcode is compared for EQUALITY and only after trimming: an EAN-13 or
/// a Code128 payload has no spaces, and a substring test would let "89012"
/// light up half the catalogue. Name, SKU and HSN keep the substring behaviour a
/// type-ahead needs.
///
/// [query] is trimmed here, so callers may pass the raw field text.
bool itemSuggestionMatches(ItemSuggestion item, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return false;
  if (itemSuggestionExactMatch(item, query)) return true;
  return item.name.toLowerCase().contains(q) ||
      (item.sku ?? '').trim().toLowerCase().contains(q) ||
      (item.hsn ?? '').trim().toLowerCase().contains(q);
}

/// True when [query] IS one of [item]'s identifiers — the whole name, the whole
/// SKU, the whole HSN or the whole barcode, case- and whitespace-insensitively.
///
/// This is the test that decides whether the type-ahead may offer its "Save
/// item" row: a value an existing row already claims must never be offered as
/// a new one, whichever field claims it.
bool itemSuggestionExactMatch(ItemSuggestion item, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return false;
  return item.name.trim().toLowerCase() == q ||
      (item.sku ?? '').trim().toLowerCase() == q ||
      (item.hsn ?? '').trim().toLowerCase() == q ||
      (item.barcode ?? '').trim().toLowerCase() == q;
}
