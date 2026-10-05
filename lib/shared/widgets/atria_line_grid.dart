import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/gst.dart';
import '../../core/constants/units.dart';
// Only for `UnitEntity`, the row type behind a firm-defined unit.
import '../../core/database/app_database.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/responsive/platform_ui.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/utils/formatters.dart';
import 'atria_grid_cell.dart';

/// One column of an [AtriaLineGrid].
///
/// The grid owns the column geometry and the labels, so every document editor
/// (invoice, quotation, SO, delivery note, purchase bill, debit note) renders
/// the *same* line grid: a header row on a desktop window, a labelled card per
/// line on a phone. Cells are bare inputs — no per-field label, no box — which
/// is what makes the wide layout read like a spreadsheet instead of a stack of
/// forms.
class AtriaLineColumn {
  const AtriaLineColumn(
    this.label, {
    this.flex = 2,
    this.numeric = false,
    this.wideOnly = false,
  });

  /// Header text (wide) / field label (stacked).
  final String label;

  /// Horizontal share of the grid.
  final int flex;

  /// Right-aligns the cell and pairs it with its neighbour when stacked.
  final bool numeric;

  /// Hidden in the stacked layout — for cells only legible at grid width.
  final bool wideOnly;
}

/// A single line of the grid. [cells] must be in the same order as the
/// grid's [AtriaLineGrid.columns].
class AtriaLineGridRow {
  const AtriaLineGridRow({
    required this.cells,
    this.onRemove,
    this.removeTooltip = 'Remove line',
  });

  final List<Widget> cells;

  /// Delete affordance in the row's gutter. Null hides it (e.g. the last
  /// remaining line).
  final VoidCallback? onRemove;
  final String removeTooltip;
}

/// The shared document line editor.
///
/// Wide: a bordered table with a header row, a numbered gutter and hairline
/// separators — "simple as Excel". The active cell gets the theme's green
/// focus ring and nothing else moves, so tabbing across a line and down into
/// the next is the whole interaction model.
///
/// Narrow: each line becomes a small card with its column labels above the
/// inputs — the same widget tree, just re-flowed, so a phone never gets a
/// horizontal scroller.
class AtriaLineGrid extends StatelessWidget {
  const AtriaLineGrid({
    super.key,
    required this.columns,
    required this.rows,
    required this.onAddRow,
    this.addLabel = 'Add line',
    this.addHint = 'Tab between cells · Enter starts the next line',
    this.showAddRow = true,
    this.emptyHint,
  });

  final List<AtriaLineColumn> columns;
  final List<AtriaLineGridRow> rows;
  final VoidCallback onAddRow;
  final String addLabel;
  final String? addHint;
  final bool showAddRow;
  final String? emptyHint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // A phone stacks every line as a card, whatever the window measures —
        // nine columns squeezed into a row is the failure that made a saved
        // invoice show only its Item column. Only the desktop surface chooses
        // by width.
        final wide = !Theme.of(context).platform.isMobileUi &&
            constraints.maxWidth >= Breakpoints.medium;
        if (rows.isEmpty && emptyHint != null) {
          return _EmptyLines(hint: emptyHint!);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide) _Sheet(columns: columns, rows: rows),
            if (!wide) ...[
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _StackedLine(index: i, columns: columns, row: rows[i]),
              ],
            ],
            if (showAddRow)
              _AddLineRow(label: addLabel, hint: addHint, onTap: onAddRow),
          ],
        );
      },
    );
  }
}

/// The spreadsheet surface: hairline border, header row, numbered gutter.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.columns, required this.rows});

  final List<AtriaLineColumn> columns;
  final List<AtriaLineGridRow> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = [
      for (var i = 0; i < columns.length; i++)
        (index: i, column: columns[i]),
    ];
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header band — QBO/Tally grey title row over the sheet.
          Container(
            color: scheme.surfaceContainerHighest,
            child: Row(
              children: [
                const _Gutter(width: _kGutterWidth),
                for (var v = 0; v < visible.length; v++)
                  _cellBox(
                    flex: visible[v].column.flex,
                    last: v == visible.length - 1,
                    divider: scheme.outline,
                    child: _HeaderLabel(column: visible[v].column),
                  ),
              ],
            ),
          ),
          for (var i = 0; i < rows.length; i++)
            _SheetRow(index: i, visible: visible, row: rows[i]),
        ],
      ),
    );
  }
}

/// Fixed width of the numbered gutter down the left of the sheet.
const double _kGutterWidth = 40;

class _SheetRow extends StatefulWidget {
  const _SheetRow({
    required this.index,
    required this.visible,
    required this.row,
  });

  final int index;
  final List<({int index, AtriaLineColumn column})> visible;
  final AtriaLineGridRow row;

  @override
  State<_SheetRow> createState() => _SheetRowState();
}

class _SheetRowState extends State<_SheetRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = widget.row;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        // The delete *callback* is NOT gated on hover, only the glyph is. Gating the
        // callback meant a device with no pointer — an Android tablet in
        // landscape (the sheet layout starts at 840dp, well inside a tablet's
        // width) or a Windows touch laptop — had NO way to delete a line at
        // all: nothing to hover, no long-press fallback, and the stacked phone
        // layout that does carry a delete button is unreachable at that width.
        // `onLongPress` is the touch equivalent of a hover, matching what
        // `TransactionTableRow` does for its own row actions.
        child: Semantics(
          // The hover affordance is invisible to a screen reader, so the
          // capability is exposed here as well. Independent of the
          // GestureDetector below: this one is for assistive tech, that one is
          // for fingers.
          onLongPress: row.onRemove,
          hint: row.onRemove == null
              ? null
              : 'Long-press to ${row.removeTooltip.toLowerCase()}',
          child: GestureDetector(
            onLongPress: row.onRemove,
            behavior: HitTestBehavior.translucent,
            child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Gutter(
                  width: _kGutterWidth,
                  number: widget.index + 1,
                  // Excel's row gutter turns into a delete control on hover.
                  onRemove: row.onRemove,
                  hovered: _hovered,
                  tooltip: row.removeTooltip,
                ),
                for (var v = 0; v < widget.visible.length; v++)
                  _cellBox(
                    flex: widget.visible[v].column.flex,
                    last: v == widget.visible.length - 1,
                    divider: scheme.outline,
                    child: Align(
                      alignment: widget.visible[v].column.numeric
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: row.cells[widget.visible[v].index],
                    ),
                  ),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The numbered gutter: the line number, or a delete button while hovered.
class _Gutter extends StatelessWidget {
  const _Gutter({
    required this.width,
    this.number,
    this.onRemove,
    this.hovered = false,
    this.tooltip,
  });

  final double width;
  final int? number;
  final VoidCallback? onRemove;

  /// Whether a pointer is over the row. The gutter stays quiet — a row number,
  /// not a wall of 32 permanently-lit ✕ marks — until it is.
  ///
  /// Deliberately NOT the thing that decides whether delete is *possible*: a
  /// touch device never sets this, so gating the callback on it left an Android
  /// tablet in landscape (the sheet layout begins at 840dp, well inside a
  /// tablet's width) with no way to delete a line at all. The row's long-press
  /// is the touch path; see the caller.
  final bool hovered;

  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: scheme.outline)),
      ),
      alignment: Alignment.center,
      child: onRemove == null || !hovered
          ? Text(
              number?.toString() ?? '',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            )
          : IconButton(
              onPressed: onRemove,
              tooltip: tooltip,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              iconSize: 16,
              color: scheme.onSurfaceVariant,
              icon: const Icon(Icons.close_rounded),
            ),
    );
  }
}

/// Wraps one cell with the sheet's vertical hairline and alignment padding.
Widget _cellBox({
  required int flex,
  required bool last,
  required Color divider,
  required Widget child,
}) {
  return Expanded(
    flex: flex,
    child: Container(
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(right: BorderSide(color: divider)),
            ),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: child,
    ),
  );
}

class _HeaderLabel extends StatelessWidget {
  const _HeaderLabel({required this.column});

  final AtriaLineColumn column;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      child: Text(
        column.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: column.numeric ? TextAlign.right : TextAlign.left,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// Phone layout: one bordered card per line, labels above the inputs.
class _StackedLine extends StatelessWidget {
  const _StackedLine({
    required this.index,
    required this.columns,
    required this.row,
  });

  final int index;
  final List<AtriaLineColumn> columns;
  final AtriaLineGridRow row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = [
      for (var i = 0; i < columns.length; i++)
        if (!columns[i].wideOnly) (index: i, column: columns[i]),
    ];

    // Cells pair up two-per-row, in the sheet's own column order, so the card
    // reads top-to-bottom the way the sheet reads left-to-right (HSN | Qty,
    // Rate | Disc, GST | Amount) instead of stranding a lone field per row.
    // The leading column is the line's identity and is rendered in the card's
    // own header row above.
    final rest = visible.skip(1).toList();
    final blocks = <List<({int index, AtriaLineColumn column})>>[];
    for (var i = 0; i < rest.length; i += 2) {
      blocks.add(i + 1 < rest.length ? [rest[i], rest[i + 1]] : [rest[i]]);
    }

    // Cells are boxed here: with no column header above them, a borderless
    // input would have no affordance at all on a phone.
    return AtriaGridCellMode(
      boxed: true,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${index + 1}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: row.cells.first,
                  ),
                ),
                if (row.onRemove != null)
                  IconButton(
                    onPressed: row.onRemove,
                    tooltip: row.removeTooltip,
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    color: scheme.onSurfaceVariant,
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
              ],
            ),
            for (final block in blocks) ...[
              const SizedBox(height: 8),
              if (block.length == 1)
                _StackedCell(
                  column: block.first.column,
                  child: row.cells[block.first.index],
                )
              else
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _StackedCell(
                          column: block[0].column,
                          child: row.cells[block[0].index],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _StackedCell(
                          column: block[1].column,
                          child: row.cells[block[1].index],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StackedCell extends StatelessWidget {
  const _StackedCell({required this.column, required this.child});

  final AtriaLineColumn column;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          column.label.toUpperCase(),
          // labelSmall (11px) is the app's smallest step; this field label was
          // the only 10px text left, so the grid's column heads sat a pixel
          // under every other caption in the product.
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        child,
      ],
    );
  }
}

class _EmptyLines extends StatelessWidget {
  const _EmptyLines({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: scheme.outline, style: BorderStyle.solid),
      ),
      child: Text(
        hint,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// The quiet green "Add line" link under the sheet, with an optional reminder
/// of the keyboard model — the Excel half of the editor's promise.
class _AddLineRow extends StatelessWidget {
  const _AddLineRow({required this.label, required this.onTap, this.hint});

  final String label;
  final VoidCallback onTap;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: onTap,
            style: TextButton.styleFrom(
              foregroundColor: scheme.primary,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(
              label,
              style: text.titleSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                hint!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A borderless input sized for a grid cell.
///
/// At rest it is indistinguishable from the surface — the column header says
/// what it is. On focus the theme's green ring appears, which is precisely
/// Excel's active-cell cue. In the stacked (phone) layout the same input is
/// hairline-boxed instead, because there the labels sit above the cells and a
/// borderless box would have no affordance at all.
class AtriaGridInput extends StatelessWidget {
  const AtriaGridInput({
    super.key,
    required this.controller,
    this.hint,
    this.prefix,
    this.suffix,
    this.onChanged,
    this.onSubmitted,
    this.validator,
    this.textAlign = TextAlign.left,
    this.numeric = false,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.focusNode,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String? hint;
  final String? prefix;
  final String? suffix;
  final ValueChanged<String>? onChanged;

  /// The cell's Enter, and part of the sheet's contract rather than a nicety:
  /// every cell wires it to the host's `advance()`, so Enter walks along the
  /// row and the last line's Enter starts a new one. A cell that leaves it null
  /// swallows Enter (the field keeps focus and nothing moves), which is how the
  /// HSN cell used to break a keyboard run halfway down the line. The Item cell
  /// is the one cell that cannot honour this from here — its type-ahead owns
  /// the key event — so it needs the shared field to forward Enter.
  final VoidCallback? onSubmitted;

  final String? Function(String?)? validator;
  final TextAlign textAlign;
  final bool numeric;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;
  final FocusNode? focusNode;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      textAlign: textAlign,
      textCapitalization: textCapitalization,
      inputFormatters: inputFormatters,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      // Enter moves down the column, the way a spreadsheet does — and the
      // host uses the last cell's Enter to start a new line. See
      // [onSubmitted]: every cell passes it, or Enter stops here.
      textInputAction: TextInputAction.next,
      onChanged: onChanged,
      onFieldSubmitted: (_) => onSubmitted?.call(),
      validator: validator,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        fontWeight: numeric ? FontWeight.w600 : FontWeight.w500,
        fontFeatures: numeric ? const [FontFeature.tabularFigures()] : null,
      ),
      decoration: AtriaGridCell.decorationFor(
        context,
        hint: hint,
        prefix: prefix,
        suffix: suffix,
      ),
    );
  }
}

/// Bare measurement-unit picker for a grid cell — Tally's UOM, one tap away.
class AtriaUnitPicker extends StatelessWidget {
  const AtriaUnitPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.customUnits = const [],
  });

  final String value;
  final ValueChanged<String> onChanged;

  /// The firm's own units, on top of [Unit.standard].
  ///
  /// The picker used to offer only the standard set plus "whatever value this
  /// line already had". That made a unit created in the item editor
  /// (`ItemRepository.createUnit`) disappear from the dropdown the moment the
  /// person changed the unit on a line — and with nothing left to select it
  /// back to, it was unrecoverable for the rest of the session.
  final List<UnitEntity> customUnits;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final boxed = AtriaGridCellMode.boxedOf(context);
    return AtriaGridCell.boxed(
      context,
      DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          iconSize: AppIconSize.md,
          value: value,
          isDense: true,
          isExpanded: true,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
          icon: boxed
              ? const Icon(Icons.expand_more_rounded, size: 16)
              : const SizedBox.shrink(),
          items: [
            for (final unit in Unit.standard)
              DropdownMenuItem<String>(
                value: unit.id,
                child: Text(unit.symbol, maxLines: 1),
              ),
            for (final unit in customUnits)
              DropdownMenuItem<String>(
                value: unit.symbol,
                child: Text('${unit.symbol} · ${unit.name}', maxLines: 1),
              ),
            // A value carried in from an imported item that is in neither list
            // still has to appear, or `DropdownButton` asserts on the value.
            if (Unit.byId(value) == null &&
                !customUnits.any((u) => u.symbol == value))
              DropdownMenuItem<String>(value: value, child: Text(value)),
          ],
          onChanged: (next) {
            if (next != null && next != value) onChanged(next);
          },
        ),
      ),
    );
  }
}

/// Bare GST-rate picker for a grid cell, with the rate off the standard slab
/// (an imported or custom item) still selectable.
class AtriaGstRatePicker extends StatelessWidget {
  const AtriaGstRatePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return AtriaGridCell.boxed(
      context,
      DropdownButtonHideUnderline(
        child: DropdownButton<double>(
          iconSize: AppIconSize.md,
          value: value,
          isDense: true,
          isExpanded: true,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(fontWeight: FontWeight.w600),
          icon: const Icon(Icons.expand_more_rounded, size: 16),
          items: [
            for (final rate in GstRate.standard)
              DropdownMenuItem<double>(
                value: rate.rate,
                child: Text(rate.rate > 0 ? rate.label : 'No GST'),
              ),
            if (GstRate.fromDouble(value) == null)
              DropdownMenuItem<double>(
                value: value,
                child: Text(Formatters.percent(value)),
              ),
          ],
          onChanged: (next) {
            if (next != null && next != value) onChanged(next);
          },
        ),
      ),
    );
  }
}
