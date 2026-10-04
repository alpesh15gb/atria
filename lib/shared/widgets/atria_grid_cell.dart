import 'package:flutter/material.dart';

import '../../core/theme/app_radius.dart';

/// Tells the cells inside an [AtriaLineGrid] how they are being laid out.
///
/// A grid cell is deliberately bare: in the desktop sheet the column header
/// says what the cell is, and a borderless input *is* the spreadsheet look.
/// On a phone the grid re-flows into a card per line with the label above each
/// cell — and there a borderless input is invisible, so the cell is boxed
/// instead. The grid sets this once; every cell reads it, including the
/// non-text cells (dropdowns, the item type-ahead) that build their own
/// decoration.
class AtriaGridCellMode extends InheritedWidget {
  const AtriaGridCellMode({
    super.key,
    required this.boxed,
    required super.child,
  });

  /// True in the stacked (phone) layout.
  final bool boxed;

  static AtriaGridCellMode? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AtriaGridCellMode>();

  static bool boxedOf(BuildContext context) => maybeOf(context)?.boxed ?? false;

  @override
  bool updateShouldNotify(AtriaGridCellMode oldWidget) =>
      oldWidget.boxed != boxed;
}

/// The one place a grid cell's input decoration is built, so the sheet cell
/// and the stacked card cell cannot drift apart.
class AtriaGridCell {
  const AtriaGridCell._();

  static const OutlineInputBorder _borderless = OutlineInputBorder(
    borderSide: BorderSide(color: Colors.transparent),
    borderRadius: AppRadius.xsAll,
  );

  /// The cell decoration: borderless at rest in the sheet — the green focus
  /// ring on focus is Excel's active cell — and hairline-boxed in the stacked
  /// layout, where there is no column header to explain the input.
  static InputDecoration decorationFor(
    BuildContext context, {
    String? hint,
    String? prefix,
    String? suffix,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final boxed = AtriaGridCellMode.boxedOf(context);
    final InputBorder border = boxed
        ? OutlineInputBorder(
            borderSide: BorderSide(color: scheme.outline),
            borderRadius: BorderRadius.circular(AppRadius.xs),
          )
        : _borderless;
    return InputDecoration(
      isDense: true,
      filled: false,
      hintText: hint,
      prefixText: prefix,
      suffixText: suffix,
      counterText: '',
      // Never floats: keeps every cell's text on the same baseline.
      floatingLabelBehavior: FloatingLabelBehavior.never,
      contentPadding: EdgeInsets.symmetric(
        horizontal: boxed ? 10 : 8,
        vertical: boxed ? 13 : 10,
      ),
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: scheme.primary, width: 2),
        borderRadius: AppRadius.xsAll,
      ),
    );
  }

  /// Wraps a cell that is not a text input (a bare dropdown) so it reads as a
  /// field in the stacked layout. A no-op in the sheet, where the cell must
  /// stay flush with its neighbours.
  static Widget boxed(BuildContext context, Widget child) {
    if (!AtriaGridCellMode.boxedOf(context)) return child;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: child,
    );
  }

  /// Hairline box for a cell whose content is a computed figure rather than an
  /// input (a line amount). Null in the sheet, where the figure stays bare and
  /// right-aligned under its column heading.
  static BoxDecoration? boxDecorationOf(BuildContext context) {
    if (!AtriaGridCellMode.boxedOf(context)) return null;
    return BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outline),
      borderRadius: BorderRadius.circular(AppRadius.xs),
    );
  }
}
