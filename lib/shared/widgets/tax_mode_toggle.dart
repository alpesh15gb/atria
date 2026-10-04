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

/// A one-tap pill for grid rows: shows the current mode and cycles it.
///
/// The full segmented [TaxModeToggle] needs ~150px — more than a spreadsheet
/// column can spare — so the line grid gets this instead, and the phone's
/// stacked layout keeps the segmented control.
///
/// The pill is painted ~26dp tall but owns a 44dp target: the cells around it
/// size to their tallest child, so the extra height makes a row 44 instead of
/// 26 and moves nothing else. A 26dp target is unusable with a thumb, and the
/// line grid is exactly where a thumb is.
class AtriaTaxModePill extends StatelessWidget {
  const AtriaTaxModePill({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final TaxMode value;
  final ValueChanged<TaxMode> onChanged;

  /// The accessible target, per the platform minimum. See the class doc.
  static const double _targetSize = 44;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inclusive = value == TaxMode.inclusive;
    final radius = BorderRadius.circular(4);
    return Tooltip(
      message: inclusive
          ? 'The rate already includes GST — tap for GST on top'
          : 'GST is added on top of the rate — tap for an inclusive rate',
      child: Semantics(
        button: true,
        child: Material(
          // Its own Material. An `InkWell` with no `Material` ancestor does not
          // throw and does not splash — the tap still works, so a pill placed
          // outside a Material looked like a control with no feedback at all.
          // A transparent Material supplies the ink layer and nothing else.
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () => onChanged(
              inclusive ? TaxMode.exclusive : TaxMode.inclusive,
            ),
            borderRadius: radius,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: _targetSize,
                minHeight: _targetSize,
              ),
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  decoration: BoxDecoration(
                    color: inclusive
                        ? scheme.primaryContainer
                        : Colors.transparent,
                    borderRadius: radius,
                  ),
                  child: Text(
                    inclusive ? 'Incl' : 'Excl',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: inclusive
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
