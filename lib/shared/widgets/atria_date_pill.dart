import 'package:flutter/material.dart';

import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';

/// The hairline date pill — tap it to open the date picker.
///
/// Lifted out of `period_selector.dart` rather than copied: the reports screen
/// and the six list screens both needed one, and the first version of this had
/// two subtly different pills — one with a Material ink ripple and a trailing
/// calendar icon, one with a bare `GestureDetector` and no icon. A date pill
/// that looks different in two places reads as two different features.
class AtriaDatePill extends StatelessWidget {
  const AtriaDatePill({
    super.key,
    required this.label,
    required this.value,
    required this.onPicked,
    this.fromDate,
    this.toDate,
    this.showIcon = true,
  });

  /// "From" / "To" / "Start" / "End" — what this end of the range is.
  final String label;

  final DateTime value;

  /// Called with the picked day, or never if the picker is dismissed.
  final ValueChanged<DateTime> onPicked;

  /// Earliest day the picker will offer. Default 2020 — before any firm that
  /// used this app existed.
  final DateTime? fromDate;

  /// Latest day the picker will offer. Default **today**: a window that ends in
  /// the future shows nothing but a lie about what has happened.
  final DateTime? toDate;

  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final radius = BorderRadius.circular(AppRadius.pill);

    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: value,
            firstDate: fromDate ?? DateTime(2020),
            lastDate: toDate ?? DateTime.now(),
            helpText: helpText,
          );
          if (picked != null) onPicked(picked);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: scheme.outline, width: 0.9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: text.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                Formatters.date(value),
                style: text.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (showIcon) ...[
                const SizedBox(width: 4),
                Icon(Icons.event_rounded, size: 13, color: scheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The picker's own title, derived from the pill's label.
  ///
  /// "From" and "To" are ambiguous on a date picker — they read as a *field*
  /// name, not a question. The dialog asks what the chosen day will do.
  String get helpText => switch (label) {
    'From' || 'Start' => 'Window starts on',
    'To' || 'End' => 'Window ends on',
    _ => 'Pick $label',
  };
}
