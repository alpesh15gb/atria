import 'package:flutter/material.dart';

import '../../core/reports/window/report_window.dart';
import '../../core/utils/formatters.dart';
import 'atria_date_pill.dart';
import 'atria_list_toolbar.dart';

/// Which window of records a list screen shows. [custom] means the user's own
/// From/To days, carried alongside the enum in a [PeriodRange].
enum Period { thisMonth, thisFY, allTime, custom }

/// Human label for a [Period], shared by every list screen so the same window
/// never reads differently in two places.
String periodLabel(Period period) => switch (period) {
  Period.thisMonth => 'This Month',
  Period.thisFY => 'This FY',
  Period.allTime => 'All Time',
  Period.custom => 'Custom',
};

/// The period filter's options, in one place so every list screen offers the
/// same four windows under the same `Date:` label.
List<AtriaSegment<Period>> periodSegments() => [
  for (final period in Period.values)
    AtriaSegment<Period>(value: period, label: periodLabel(period)),
];

/// A resolved window of records: the bounds to query with, the label to print,
/// and — for [Period.custom] — the two days the From/To pills edit.
///
/// The named windows stay open-ended at the top (`to == null`) so a record
/// dated later today is never cut off. Only a custom window closes, at the end
/// of its last day.
class PeriodRange {
  PeriodRange({required this.period, DateTime? customFrom, DateTime? customTo})
    : customFrom = customFrom ?? _startOfMonth(DateTime.now()),
      customTo = customTo ?? DateTime.now();

  final Period period;

  /// The days the From/To pills show and edit. Unused unless [isCustom].
  final DateTime customFrom;
  final DateTime customTo;

  bool get isCustom => period == Period.custom;
  bool get isAllTime => period == Period.allTime;

  /// Value equality, so a provider handing out a fresh instance for an
  /// unchanged window does not rebuild every list that watches it.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeriodRange &&
          other.period == period &&
          other.customFrom == customFrom &&
          other.customTo == customTo;

  @override
  int get hashCode => Object.hash(period, customFrom, customTo);

  /// First day included by the window; null when it is open-ended (All Time).
  DateTime? get from => switch (period) {
    Period.allTime => null,
    Period.thisMonth => _startOfMonth(DateTime.now()),
    Period.thisFY => _startOfFinancialYear(DateTime.now()),
    Period.custom => _dayOnly(_firstDay),
  };

  /// Last day included by the window (end of that day); null when the window
  /// is open-ended at the top.
  DateTime? get to => switch (period) {
    Period.custom => _endOfDay(_lastDay),
    _ => null,
  };

  /// What the UI calls this window — "This Month", "All Time", or the two
  /// dates a custom window spans.
  String get label => period == Period.custom
      ? '${Formatters.date(from!)}  –  ${Formatters.date(to!)}'
      : periodLabel(period);

  /// One key per distinct window, so a screen can cache the Drift watch it
  /// builds per filter combination without comparing dates by hand.
  String get cacheKey =>
      '${period.name}|'
      '${from?.microsecondsSinceEpoch ?? 0}|'
      '${to?.microsecondsSinceEpoch ?? 0}';

  /// The same days under a different filter option, so switching away from
  /// Custom and back does not lose the dates the user picked.
  PeriodRange withPeriod(Period period) =>
      PeriodRange(period: period, customFrom: customFrom, customTo: customTo);

  /// The window with one of its two custom days replaced, kept on Custom.
  PeriodRange withCustomDay({DateTime? from, DateTime? to}) => PeriodRange(
    period: Period.custom,
    customFrom: from ?? customFrom,
    customTo: to ?? customTo,
  );

  /// The sentence a list screen prints under "Nothing in <label>": it names
  /// the window that emptied the list and the way out of it.
  String emptyWindowMessage(String noun) => period == Period.custom
      ? 'There are no $noun between ${Formatters.date(from!)} and '
            '${Formatters.date(to!)}. Widen the range, or switch the Date '
            'filter to All Time.'
      : 'There are no $noun from ${Formatters.date(from!)} onwards. Switch '
            'the Date filter to All Time to see older ones.';

  /// The two picked days in order, so choosing "To" before "From" still gives
  /// a sensible window instead of an empty one.
  DateTime get _firstDay =>
      customFrom.isAfter(customTo) ? customTo : customFrom;
  DateTime get _lastDay => customFrom.isAfter(customTo) ? customFrom : customTo;

  /// This range as a [ReportWindow] — the one window type every report and
  /// list screen now speaks.
  ///
  /// The mapping is exact because [Period] is a subset of
  /// [ReportWindowPreset]. Note the deliberate asymmetry in the bounds: the
  /// named windows stay open-ended at the top here, exactly as they always
  /// were. A list screen filtering "this month" must not hide a row saved ten
  /// seconds ago, and a report that closes its window at midnight sharp has a
  /// different answer to that question — so this preserves the list behaviour
  /// rather than the report behaviour.
  ReportWindow toWindow() => switch (period) {
    Period.allTime => const ReportWindow(
      preset: ReportWindowPreset.allTime,
      from: null,
      to: null,
    ),
    Period.thisMonth => ReportWindow(
      preset: ReportWindowPreset.thisMonth,
      from: _startOfMonth(DateTime.now()),
      to: null,
    ),
    Period.thisFY => ReportWindow(
      preset: ReportWindowPreset.thisFY,
      from: _startOfFinancialYear(DateTime.now()),
      to: null,
    ),
    Period.custom => ReportWindow(
      preset: ReportWindowPreset.custom,
      from: _dayOnly(_firstDay),
      to: _endOfDay(_lastDay),
    ),
  };

  /// The other direction, for a screen that holds a [ReportWindow] and needs to
  /// feed the shared list-screen filter.
  ///
  /// [ReportWindowPreset.thisQuarter] has no [Period] — the list screens have
  /// never offered a quarter — so it maps to [Period.custom] carrying its own
  /// days rather than to the nearest named period, which would silently show a
  /// different range than the one the report computed.
  static PeriodRange fromWindow(ReportWindow window) => switch (window.preset) {
    ReportWindowPreset.allTime => PeriodRange(period: Period.allTime),
    ReportWindowPreset.thisMonth => PeriodRange(period: Period.thisMonth),
    ReportWindowPreset.thisFY => PeriodRange(period: Period.thisFY),
    ReportWindowPreset.thisQuarter || ReportWindowPreset.custom => PeriodRange(
      period: Period.custom,
      customFrom: window.from ?? _startOfMonth(DateTime.now()),
      customTo: window.to ?? DateTime.now(),
    ),
  };
}

/// The From/To date pills a [Period.custom] window needs, shown beside the
/// Date filter. The same picker the Reports screen offers, so a custom window
/// is chosen and reads the same in both places.
class PeriodCustomRange extends StatelessWidget {
  const PeriodCustomRange({
    super.key,
    required this.range,
    required this.onChanged,
  });

  final PeriodRange range;
  final ValueChanged<PeriodRange> onChanged;

  @override
  Widget build(BuildContext context) {
    // A [Wrap], not a [Row]: the two pills are the widest thing in the filter
    // strip, and on a phone (or at a large text scale) stacking them beats a
    // striped overflow banner — or a clipped date the user cannot read.
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        AtriaDatePill(
          label: 'From',
          value: range.customFrom,
          onPicked: (day) => onChanged(range.withCustomDay(from: day)),
        ),
        AtriaDatePill(
          label: 'To',
          value: range.customTo,
          onPicked: (day) => onChanged(range.withCustomDay(to: day)),
        ),
      ],
    );
  }
}

DateTime _startOfMonth(DateTime day) => DateTime(day.year, day.month, 1);

/// Indian financial years run 1 April → 31 March.
DateTime _startOfFinancialYear(DateTime day) =>
    day.month >= 4 ? DateTime(day.year, 4, 1) : DateTime(day.year - 1, 4, 1);

DateTime _dayOnly(DateTime day) => DateTime(day.year, day.month, day.day);

DateTime _endOfDay(DateTime day) =>
    DateTime(day.year, day.month, day.day, 23, 59, 59);
