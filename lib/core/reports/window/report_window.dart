import 'package:flutter/foundation.dart';

import '../../engine/document_numbering.dart';
import '../../utils/formatters.dart';

/// The named windows a report can be scoped to.
///
/// Deliberately a superset of the three enums this replaces: `Period` on the
/// six list screens (This Month / This FY / All Time / Custom), the private
/// `_Period` on the reports screen (which also offered This Quarter), and the
/// nullable `DateTimeRange` the ledger reports carried. Three enums for one
/// idea is three places a quarter-end bug can hide.
enum ReportWindowPreset {
  thisMonth,
  thisQuarter,
  thisFY,
  allTime,
  custom;

  /// What a chip or button calls this window.
  String get label => switch (this) {
    ReportWindowPreset.thisMonth => 'This Month',
    ReportWindowPreset.thisQuarter => 'This Quarter',
    ReportWindowPreset.thisFY => 'This FY',
    ReportWindowPreset.allTime => 'All Time',
    ReportWindowPreset.custom => 'Custom',
  };
}

/// A resolved window of records: which days a report covers.
///
/// [from] is inclusive and [to] is inclusive at the end of that day
/// (23:59:59). **Either may be null, meaning unbounded on that side** — All
/// Time is `from == null && to == null`, and the list screens' "This Month"
/// window is `to == null` so a record dated later today is never cut off.
/// Nullability is not a convenience here; it is what three of the four presets
/// the app already ships require, and collapsing it would force every open-ended
/// query through a sentinel date that is never in the data.
///
/// This is a **pure value**: it stores its bounds and never recomputes them.
/// Preset resolution happens once, in [resolve], against a caller-supplied
/// `now`. That split is what makes it safe to compare by `==` (see
/// [ReportWindowPreset.thisQuarter] below) and safe to put in a stream cache
/// key.
@immutable
class ReportWindow {
  const ReportWindow({
    required this.preset,
    required this.from,
    required this.to,
  });

  /// The resolved bounds of [preset], evaluated against [now].
  ///
  /// Pass [now] explicitly in tests; it defaults to the wall clock.
  ///
  /// **The load-bearing rule: a named window closes at its own fixed end, never
  /// at `now`.** For the ~three quarters of a financial year that are still in
  /// progress — and for the financial year itself — the last day is known in
  /// advance. Ending such a window at `now` put a wall-clock timestamp into a
  /// value that has `==` on its bounds, so every rebuild produced a *different*
  /// window and every `didUpdateWidget` re-issued its queries: changing the
  /// day-book date, resizing the window, or any ancestor rebuild re-ran the
  /// whole books from scratch. A quarter that has not ended cannot contain a
  /// row dated after its last day, so closing at the quarter's real end returns
  /// exactly the same rows while comparing equal every time.
  ///
  /// The exception is [ReportWindowPreset.thisMonth], whose end genuinely moves
  /// — with the day, not with the millisecond, since it closes at 23:59:59.
  static ReportWindow resolve(
    ReportWindowPreset preset, {
    DateTime? now,
    DateTime? customFrom,
    DateTime? customTo,
  }) {
    final today = _dayOnly(now ?? DateTime.now());
    switch (preset) {
      case ReportWindowPreset.allTime:
        return ReportWindow(preset: preset, from: null, to: null);

      case ReportWindowPreset.thisMonth:
        return ReportWindow(
          preset: preset,
          from: DateTime(today.year, today.month, 1),
          to: _endOfDay(today),
        );

      case ReportWindowPreset.thisFY:
        final fy = FinancialYear.forDate(today);
        return ReportWindow(preset: preset, from: fy.start, to: fy.end);

      case ReportWindowPreset.thisQuarter:
        // Quarters follow the Indian financial year: Apr-Jun, Jul-Sep, ...
        final fy = FinancialYear.forDate(today);
        final elapsed =
            (today.year - fy.start.year) * 12 + today.month - fy.start.month;
        final quarter = elapsed.clamp(0, 11) ~/ 3;
        final start = DateTime(fy.start.year, fy.start.month + quarter * 3, 1);
        // Day 0 of the month *after* the quarter is the quarter's last day, so
        // this is right for 28-, 30- and 31-day months without a lookup table.
        final end = DateTime(
          fy.start.year,
          fy.start.month + quarter * 3 + 3,
          0,
          23,
          59,
          59,
        );
        return ReportWindow(preset: preset, from: start, to: end);

      case ReportWindowPreset.custom:
        final from = customFrom ?? DateTime(today.year, today.month, 1);
        final to = customTo ?? today;
        // Order the pair rather than refusing it: choosing "To" before "From"
        // should give a sensible window, not an empty one.
        return ReportWindow(
          preset: preset,
          from: _dayOnly(from.isAfter(to) ? to : from),
          to: _endOfDay(from.isAfter(to) ? from : to),
        );
    }
  }

  /// Which named window this is. Reports group, label and cache on it, and it
  /// is the only field that distinguishes "the same days, chosen twice by
  /// different routes" — hence its place in [cacheKey] rather than [==].
  final ReportWindowPreset preset;

  /// First day included, at the start of that day; null = unbounded below.
  final DateTime? from;

  /// Last day included, at the end of that day; null = unbounded above.
  final DateTime? to;

  bool get isOpenEnded => from == null || to == null;
  bool get isCustom => preset == ReportWindowPreset.custom;
  bool get isAllTime => from == null && to == null;

  /// Lower bound for a query that needs a real `DateTime`.
  ///
  /// The ledger reports pass an optional `from` straight through, so this is the
  /// "no lower bound" spelling rather than a floor date chosen here — a floor
  /// would silently exclude records dated before it.
  DateTime get queryFrom => from ?? DateTime(2000);

  /// Upper bound for a query that needs a real `DateTime`.
  DateTime get queryTo => to ?? _endOfDay(DateTime.now());

  /// What the UI calls this window — the preset's name, or the two days a
  /// custom window spans.
  String get label => isCustom ? spanLabel : preset.label;

  /// Always the two days, whatever the preset.
  ///
  /// Report subtitles print this beside the figures they summarise. A named
  /// window's own name ("This Month") is no use there: the number the reader is
  /// looking at has a concrete start and end, and those are what has to be on
  /// the page.
  String get spanLabel => isAllTime
      ? 'All of time'
      : isOpenEnded
      ? '${from == null ? '…' : Formatters.date(from!)} onwards'
      : '${Formatters.date(from!)}  –  ${Formatters.date(to!)}';

  /// One key per distinct window, so a screen can cache the query it builds
  /// without comparing dates by hand.
  String get cacheKey =>
      '${preset.name}|'
      '${from?.microsecondsSinceEpoch ?? 0}|'
      '${to?.microsecondsSinceEpoch ?? 0}';

  /// Whether a row dated [moment] falls inside this window.
  bool contains(DateTime moment) =>
      (from == null || !moment.isBefore(from!)) &&
      (to == null || !moment.isAfter(to!));

  /// The same window under a different [preset].
  ///
  /// Carries [ReportWindow.custom]'s bounds across the round trip so switching
  /// away from Custom and back does not lose the days the user picked — the
  /// one piece of state this value type has to keep for its callers.
  ReportWindow withPreset(
    ReportWindowPreset preset, {
    DateTime? customFrom,
    DateTime? customTo,
  }) => resolve(
    preset,
    customFrom: customFrom ?? (isCustom ? from : null),
    customTo: customTo ?? (isCustom ? to : null),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReportWindow &&
          other.preset == preset &&
          other.from == from &&
          other.to == to;

  @override
  int get hashCode => Object.hash(preset, from, to);

  @override
  String toString() => 'ReportWindow($cacheKey)';
}

DateTime _dayOnly(DateTime day) => DateTime(day.year, day.month, day.day);

DateTime _endOfDay(DateTime day) =>
    DateTime(day.year, day.month, day.day, 23, 59, 59);
