import 'package:flutter/material.dart';

/// Which window of records a list screen shows.
enum Period { thisMonth, thisFY, allTime }

/// Start of the date window for [period]. The window is open-ended (null `to`)
/// so records created later today are never cut off.
DateTime? periodStart(Period period) {
  final now = DateTime.now();
  switch (period) {
    case Period.thisMonth:
      return DateTime(now.year, now.month, 1);
    case Period.thisFY:
      // Indian financial years run 1 April → 31 March.
      return now.month >= 4
          ? DateTime(now.year, 4, 1)
          : DateTime(now.year - 1, 4, 1);
    case Period.allTime:
      return null;
  }
}

/// Human label for a [Period], shared by every list screen so the same window
/// never reads differently in two places.
String periodLabel(Period period) => switch (period) {
      Period.thisMonth => 'This Month',
      Period.thisFY => 'This FY',
      Period.allTime => 'All Time',
    };

/// The segmented pill row used to pick a [Period].
///
/// Every segment carries an [InkWell] so taps ripple — the bare
/// GestureDetector this replaces swallowed the press entirely, which read as
/// "the app didn't hear me" on every list screen that used it.
class PeriodPillRow extends StatelessWidget {
  const PeriodPillRow({super.key, required this.value, required this.onChanged});

  final Period value;
  final ValueChanged<Period> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            for (final period in Period.values)
              Expanded(
                child: _PeriodPill(
                  period: period,
                  selected: value == period,
                  onTap: () => onChanged(period),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PeriodPill extends StatelessWidget {
  const _PeriodPill({
    required this.period,
    required this.selected,
    required this.onTap,
  });

  final Period period;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.10),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Text(
            periodLabel(period),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
          ),
        ),
      ),
    );
  }
}
