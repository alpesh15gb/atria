import 'package:flutter/material.dart';

import '../../core/reports/window/report_window.dart';
import 'atria_date_pill.dart';

/// The period strip every report screen shows: one chip per named window, and
/// the two date pills when [ReportWindowPreset.custom] is selected.
///
/// Extracted from the reports screen's private `_periodSelector` so the 47
/// report pages inherit it rather than each re-deciding how wide a chip row
/// scrolls on a phone. The From/To pills are the shared [AtriaDatePill], so a
/// custom window looks the same here as it does on the six list screens.
class ReportPeriodToolbar extends StatelessWidget {
  const ReportPeriodToolbar({
    super.key,
    required this.window,
    required this.onChanged,
    this.presets = defaultPresets,
    this.padding = const EdgeInsets.fromLTRB(16, 6, 16, 4),
  });

  final ReportWindow window;
  final ValueChanged<ReportWindow> onChanged;

  /// Which windows to offer, in order. Defaults to the four the app has always
  /// shown on the reports screen.
  final List<ReportWindowPreset> presets;

  final EdgeInsetsGeometry padding;

  static const List<ReportWindowPreset> defaultPresets = [
    ReportWindowPreset.thisMonth,
    ReportWindowPreset.thisQuarter,
    ReportWindowPreset.thisFY,
    ReportWindowPreset.custom,
  ];

  /// Resolves the next window, carrying a custom range's days across the switch
  /// so returning to Custom shows the days the user last picked rather than
  /// resetting to this month's first day.
  ReportWindow _select(ReportWindowPreset preset) {
    if (preset != ReportWindowPreset.custom) {
      return ReportWindow.resolve(preset);
    }
    final now = DateTime.now();
    return ReportWindow.resolve(
      preset,
      customFrom: window.isCustom
          ? window.from
          : DateTime(now.year, now.month, 1),
      customTo: window.isCustom ? window.to : now,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              shrinkWrap: true,
              itemCount: presets.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final preset = presets[index];
                final selected = window.preset == preset;
                return ChoiceChip(
                  label: Text(
                    preset.label,
                    style: text.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  selected: selected,
                  showCheckmark: false,
                  onSelected: (_) => onChanged(_select(preset)),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.event_available_rounded,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              if (window.isCustom) ...[
                // A [Wrap] would be safer than a [Row] here, but the chips above
                // already scroll and this row has exactly two pills; the label
                // branch below is the one that can run out of room, and it
                // ellipsises.
                Flexible(
                  child: AtriaDatePill(
                    label: 'From',
                    value: window.from ?? DateTime.now(),
                    onPicked: (day) => onChanged(
                      ReportWindow.resolve(
                        ReportWindowPreset.custom,
                        customFrom: day,
                        customTo: window.to,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: AtriaDatePill(
                    label: 'To',
                    value: window.to ?? DateTime.now(),
                    onPicked: (day) => onChanged(
                      ReportWindow.resolve(
                        ReportWindowPreset.custom,
                        customFrom: window.from,
                        customTo: day,
                      ),
                    ),
                  ),
                ),
              ] else
                Flexible(
                  child: Text(
                    window.spanLabel,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
