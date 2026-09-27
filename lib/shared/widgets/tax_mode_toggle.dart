import 'package:flutter/material.dart';

import '../../core/engine/gst_engine.dart';

/// GST inclusive/exclusive segmented toggle for one line or one item.
///
/// Vyapar wording: "GST included" = the entered rate already contains tax;
/// "GST excluded" (default) = tax is added on top of the rate. The engine
/// already handles both via [TaxMode] — this is the missing user control.
class TaxModeToggle extends StatelessWidget {
  const TaxModeToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.compact = true,
  });

  final TaxMode value;
  final ValueChanged<TaxMode> onChanged;

  /// Compact = short labels ("Incl. GST") for inside line cards.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SegmentedButton<TaxMode>(
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        side: WidgetStatePropertyAll(
          BorderSide(color: scheme.outlineVariant, width: 0.8),
        ),
        textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
      ),
      segments: [
        ButtonSegment(
          value: TaxMode.inclusive,
          label: Text(compact ? 'Incl. GST' : 'GST included'),
          tooltip: 'The rate already includes GST',
        ),
        ButtonSegment(
          value: TaxMode.exclusive,
          label: Text(compact ? 'Excl. GST' : 'GST excluded'),
          tooltip: 'GST is added on top of the rate',
        ),
      ],
      selected: {value},
      onSelectionChanged: (selection) {
        onChanged(selection.first);
      },
    );
  }
}
