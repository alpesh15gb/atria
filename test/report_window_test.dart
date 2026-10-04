import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/shared/widgets/period_selector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 0 — one date window.
///
/// The tests that matter here are the ones that would fail if the window went
/// back to resolving itself against `DateTime.now()` on every rebuild. That is
/// not a hypothetical: it is what `reports_screen.dart` did, and it re-ran the
/// whole books whenever an ancestor rebuilt, because the resulting value
/// compared unequal every time.
void main() {
  group('preset resolution', () {
    test('this month runs from the 1st to the end of today', () {
      final window = ReportWindow.resolve(
        ReportWindowPreset.thisMonth,
        now: DateTime(2026, 2, 14, 11, 30),
      );
      expect(window.from, DateTime(2026, 2, 1));
      expect(window.to, DateTime(2026, 2, 14, 23, 59, 59));
    });

    test('this month ignores the time of day it was resolved at', () {
      // The one preset whose end genuinely moves — but with the *day*, not with
      // the millisecond. If this ever fails, every named window needs the same
      // treatment and `resolve` is the wrong place to fix it.
      final morning = ReportWindow.resolve(
        ReportWindowPreset.thisMonth,
        now: DateTime(2026, 2, 14, 8),
      );
      final evening = ReportWindow.resolve(
        ReportWindowPreset.thisMonth,
        now: DateTime(2026, 2, 14, 21),
      );
      expect(morning, evening);
    });

    test('the financial year follows April, not January', () {
      final beforeApril = ReportWindow.resolve(
        ReportWindowPreset.thisFY,
        now: DateTime(2026, 2, 15),
      );
      expect(beforeApril.from, DateTime(2025, 4, 1));
      expect(beforeApril.to, DateTime(2026, 3, 31, 23, 59, 59));

      final afterApril = ReportWindow.resolve(
        ReportWindowPreset.thisFY,
        now: DateTime(2026, 4, 2),
      );
      expect(afterApril.from, DateTime(2026, 4, 1));
      expect(afterApril.to, DateTime(2027, 3, 31, 23, 59, 59));
    });

    test('all time is unbounded on both sides, not 2000-to-now', () {
      const window = ReportWindow(
        preset: ReportWindowPreset.allTime,
        from: null,
        to: null,
      );
      expect(window.isAllTime, isTrue);
      expect(window.from, isNull);
      expect(window.to, isNull);
    });

    test('a custom window closes at the end of its last day', () {
      final window = ReportWindow.resolve(
        ReportWindowPreset.custom,
        now: DateTime(2026, 10, 4),
        customFrom: DateTime(2026, 1, 5),
        customTo: DateTime(2026, 3, 9),
      );
      expect(window.from, DateTime(2026, 1, 5));
      expect(window.to, DateTime(2026, 3, 9, 23, 59, 59));
    });

    test('a custom window given its days backwards still covers a range', () {
      // Picking "To" before "From" must not produce a window with its ends the
      // wrong way round — that reads as "no records", which is a lie.
      final window = ReportWindow.resolve(
        ReportWindowPreset.custom,
        now: DateTime(2026, 10, 4),
        customFrom: DateTime(2026, 3, 9),
        customTo: DateTime(2026, 1, 5),
      );
      expect(window.from, DateTime(2026, 1, 5));
      expect(window.to, DateTime(2026, 3, 9, 23, 59, 59));
    });

    test('a single-day custom window is one day, not zero', () {
      final window = ReportWindow.resolve(
        ReportWindowPreset.custom,
        now: DateTime(2026, 10, 4),
        customFrom: DateTime(2026, 5, 20),
        customTo: DateTime(2026, 5, 20),
      );
      expect(window.from, DateTime(2026, 5, 20));
      expect(window.to, DateTime(2026, 5, 20, 23, 59, 59));
      expect(window.contains(DateTime(2026, 5, 20, 9)), isTrue);
    });
  });

  group('quarters', () {
    test('Q1 of the FY is April to June', () {
      final window = ReportWindow.resolve(
        ReportWindowPreset.thisQuarter,
        now: DateTime(2026, 5, 20),
      );
      expect(window.from, DateTime(2026, 4, 1));
      expect(window.to, DateTime(2026, 6, 30, 23, 59, 59));
    });

    test('Q2 is July to September', () {
      final window = ReportWindow.resolve(
        ReportWindowPreset.thisQuarter,
        now: DateTime(2026, 8, 20),
      );
      expect(window.from, DateTime(2026, 7, 1));
      expect(window.to, DateTime(2026, 9, 30, 23, 59, 59));
    });

    test('Q4 runs into the next calendar year', () {
      final window = ReportWindow.resolve(
        ReportWindowPreset.thisQuarter,
        now: DateTime(2026, 2, 15),
      );
      expect(window.from, DateTime(2026, 1, 1));
      expect(window.to, DateTime(2026, 3, 31, 23, 59, 59));
    });

    test('the last day is right for 28-, 30- and 31-day months', () {
      // Day 0 of the month *after* the quarter, rather than a hardcoded 30 —
      // June ends on the 30th and March on the 31st, and getting that wrong
      // silently drops or invents a day of postings.
      DateTime lastDay(int year, int quarterStartMonth) => ReportWindow.resolve(
        ReportWindowPreset.thisQuarter,
        now: DateTime(year, quarterStartMonth, 15),
      ).to!;

      expect(lastDay(2026, 4).day, 30); // June
      expect(lastDay(2026, 7).day, 30); // September
      expect(lastDay(2026, 10).day, 31); // December
      expect(lastDay(2027, 1).day, 31); // March
    });

    test('the leap day falls inside the right quarter', () {
      // No quarter ends in February — they run Apr-Jun, Jul-Sep, Oct-Dec,
      // Jan-Mar — so the leap day can only ever be tested by where it lands.
      // Jan 2028 is in the FY 2027-28's last quarter, and 29 Feb 2028 must be
      // inside it: a window that closed on 28 Feb would drop a real posting.
      final window = ReportWindow.resolve(
        ReportWindowPreset.thisQuarter,
        now: DateTime(2028, 1, 10),
      );
      expect(window.from, DateTime(2028, 1, 1));
      expect(window.to, DateTime(2028, 3, 31, 23, 59, 59));
      expect(window.contains(DateTime(2028, 2, 29, 18)), isTrue);
    });

    test('an in-progress quarter closes at its own end, never at now', () {
      // THE REGRESSION. On 4 Oct 2026 the Oct-Dec quarter has two months left;
      // ending it at "now" put a wall-clock timestamp inside a value that has
      // `==` on its bounds, so two rebuilds a minute apart produced two
      // "different" windows and every dependent widget re-ran its queries.
      final early = ReportWindow.resolve(
        ReportWindowPreset.thisQuarter,
        now: DateTime(2026, 10, 4, 9, 15, 1),
      );
      final late = ReportWindow.resolve(
        ReportWindowPreset.thisQuarter,
        now: DateTime(2026, 10, 4, 9, 15, 2),
      );

      expect(early.to, DateTime(2026, 12, 31, 23, 59, 59));
      expect(early, late);
      expect(early.hashCode, late.hashCode);
    });

    test('an in-progress financial year is stable too', () {
      final early = ReportWindow.resolve(
        ReportWindowPreset.thisFY,
        now: DateTime(2026, 10, 4, 9, 15, 1),
      );
      final late = ReportWindow.resolve(
        ReportWindowPreset.thisFY,
        now: DateTime(2026, 10, 4, 9, 15, 2),
      );
      expect(early, late);
      expect(early.to, DateTime(2027, 3, 31, 23, 59, 59));
    });

    test('every preset except this month is stable across a rebuild', () {
      // The property the whole type exists to guarantee, stated once for all
      // five presets rather than only for the one that once broke.
      for (final preset in ReportWindowPreset.values) {
        if (preset == ReportWindowPreset.thisMonth) continue;
        final a = ReportWindow.resolve(preset, now: DateTime(2026, 10, 4, 9));
        final b = ReportWindow.resolve(
          preset,
          now: DateTime(2026, 10, 4, 9, 1),
        );
        expect(a, b, reason: '$preset must not move with the clock');
        expect(
          a.cacheKey,
          b.cacheKey,
          reason: '$preset cache key must be stable',
        );
      }
    });

    test('resolution reads the clock it is handed, not the wall clock', () {
      // Without this, the stability test above passes for the wrong reason: a
      // `resolve` that ignored its `now` argument and read the real clock would
      // return the same value twice in a row on any single day and look stable
      // while being untestable. Resolution has to be a function of `now`, or
      // none of the date assertions in this file mean anything.
      //
      // The two dates are a year apart, so they differ in month, quarter and
      // financial year — the widest separation the calendar presets allow.
      // All Time is excluded: it is *meant* to ignore the clock.
      for (final preset in ReportWindowPreset.values) {
        if (preset == ReportWindowPreset.allTime) continue;
        final october = ReportWindow.resolve(
          preset,
          now: DateTime(2026, 10, 4),
        );
        final nextYear = ReportWindow.resolve(
          preset,
          now: DateTime(2027, 10, 4),
        );
        expect(
          october,
          isNot(nextYear),
          reason: '$preset must depend on the date it is resolved for',
        );
      }
    });
  });

  group('value semantics', () {
    test('two windows over the same days are equal', () {
      final a = ReportWindow.resolve(
        ReportWindowPreset.custom,
        customFrom: DateTime(2026, 1, 1),
        customTo: DateTime(2026, 1, 31),
      );
      final b = ReportWindow.resolve(
        ReportWindowPreset.custom,
        customFrom: DateTime(2026, 1, 1),
        customTo: DateTime(2026, 1, 31),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}, hasLength(1));
    });

    test('the same days under a different preset are different windows', () {
      // `==` must not collapse the preset away: the label, the chip and the
      // empty-state sentence are all read off it.
      const allTime = ReportWindow(
        preset: ReportWindowPreset.allTime,
        from: null,
        to: null,
      );
      final thisFy = ReportWindow.resolve(
        ReportWindowPreset.thisFY,
        now: DateTime(2026, 10, 4),
      );
      expect(allTime, isNot(thisFy));
    });

    test('cacheKey separates windows that differ by a day, not by a clock', () {
      // Windows are day-granular: the end of the 31st is 23:59:59 whatever
      // time the user happened to pass, so a cache key that moved with the
      // clock would be the same defect as a moving `to`.
      final a = ReportWindow.resolve(
        ReportWindowPreset.custom,
        customFrom: DateTime(2026, 1, 1),
        customTo: DateTime(2026, 1, 31),
      );
      final sameDayLaterClock = ReportWindow.resolve(
        ReportWindowPreset.custom,
        customFrom: DateTime(2026, 1, 1),
        customTo: DateTime(2026, 1, 31, 18, 45),
      );
      final nextDay = ReportWindow.resolve(
        ReportWindowPreset.custom,
        customFrom: DateTime(2026, 1, 1),
        customTo: DateTime(2026, 2, 1),
      );

      expect(a.cacheKey, sameDayLaterClock.cacheKey);
      expect(a.cacheKey, isNot(nextDay.cacheKey));
    });

    test('cacheKey names the preset and both bounds', () {
      const allTime = ReportWindow(
        preset: ReportWindowPreset.allTime,
        from: null,
        to: null,
      );
      expect(allTime.cacheKey, 'allTime|0|0');
    });
  });

  group('bounds', () {
    test('contains is inclusive at both ends', () {
      final window = ReportWindow.resolve(
        ReportWindowPreset.custom,
        customFrom: DateTime(2026, 1, 1),
        customTo: DateTime(2026, 1, 31),
      );
      expect(window.contains(DateTime(2026, 1, 1, 0, 0, 0)), isTrue);
      expect(window.contains(DateTime(2026, 1, 31, 23, 59, 59)), isTrue);
      expect(window.contains(DateTime(2025, 12, 31, 23, 59, 59)), isFalse);
      expect(window.contains(DateTime(2026, 2, 1, 0, 0, 0)), isFalse);
    });

    test('an open-ended window contains everything on its open side', () {
      // The list screens' "This Month" is open at the top on purpose: a row
      // saved ten seconds ago must not be filtered out by its own period.
      final listWindow = ReportWindow(
        preset: ReportWindowPreset.thisMonth,
        from: DateTime(2026, 10, 1),
        to: null,
      );
      expect(listWindow.contains(DateTime(2030, 1, 1)), isTrue);
      expect(listWindow.contains(DateTime(2026, 9, 30, 23, 59, 59)), isFalse);
    });

    test('queryFrom and queryTo give a query real dates', () {
      const allTime = ReportWindow(
        preset: ReportWindowPreset.allTime,
        from: null,
        to: null,
      );
      expect(allTime.queryFrom, DateTime(2000));
      expect(allTime.queryTo.hour, 23);
      expect(allTime.queryTo.minute, 59);
      expect(allTime.queryTo.second, 59);
    });
  });

  group('labels', () {
    test('a named window is called by its name, a custom one by its days', () {
      expect(
        ReportWindow.resolve(
          ReportWindowPreset.thisQuarter,
          now: DateTime(2026, 8, 1),
        ).label,
        'This Quarter',
      );
      expect(
        ReportWindow.resolve(
          ReportWindowPreset.custom,
          customFrom: DateTime(2026, 1, 5),
          customTo: DateTime(2026, 1, 9),
        ).label,
        contains('–'),
      );
    });

    test('spanLabel is always the days, whatever the preset', () {
      // A report subtitle prints this beside the figure. "This Quarter" there
      // tells the reader nothing about which three months the number covers.
      final window = ReportWindow.resolve(
        ReportWindowPreset.thisQuarter,
        now: DateTime(2026, 8, 1),
      );
      expect(window.spanLabel, isNot('This Quarter'));
      expect(window.spanLabel, contains('–'));
    });

    test('spanLabel names the open side of an open-ended window', () {
      final window = ReportWindow(
        preset: ReportWindowPreset.thisMonth,
        from: DateTime(2026, 10, 1),
        to: null,
      );
      expect(window.spanLabel, contains('onwards'));
      expect(
        const ReportWindow(
          preset: ReportWindowPreset.allTime,
          from: null,
          to: null,
        ).spanLabel,
        'All of time',
      );
    });
  });

  group('list screens keep their own open-ended behaviour', () {
    test('PeriodRange round-trips through ReportWindow', () {
      final range = PeriodRange(period: Period.thisMonth);
      final window = range.toWindow();
      expect(window.preset, ReportWindowPreset.thisMonth);
      expect(
        window.from,
        DateTime(DateTime.now().year, DateTime.now().month, 1),
      );
    });

    test('a list screen\'s named window stays open at the top', () {
      // The asymmetry is deliberate: a list must not hide a row saved a moment
      // ago, so its named windows have no upper bound. Collapsing this to match
      // the reports screen would hide today's rows from every list.
      final thisMonth = PeriodRange(period: Period.thisMonth).toWindow();
      final thisFy = PeriodRange(period: Period.thisFY).toWindow();
      final allTime = PeriodRange(period: Period.allTime).toWindow();

      expect(thisMonth.to, isNull);
      expect(thisFy.to, isNull);
      expect(allTime.from, isNull);
      expect(allTime.to, isNull);
    });

    test('a list screen\'s custom window matches its own bounds', () {
      final range = PeriodRange(
        period: Period.custom,
        customFrom: DateTime(2026, 1, 5),
        customTo: DateTime(2026, 1, 9),
      );
      final window = range.toWindow();
      expect(window.from, DateTime(2026, 1, 5));
      expect(window.to, DateTime(2026, 1, 9, 23, 59, 59));
      expect(window.label, PeriodRange.fromWindow(window).label);
    });

    test('a quarter window becomes a custom list range, not a wrong month', () {
      // The list screens have never offered a quarter. Mapping it onto
      // `Period.thisMonth` would show them a different set of days than the one
      // the report computed, silently.
      final quarter = ReportWindow.resolve(
        ReportWindowPreset.thisQuarter,
        now: DateTime(2026, 8, 1),
      );
      final back = PeriodRange.fromWindow(quarter);
      expect(back.period, Period.custom);
      expect(back.toWindow().from, quarter.from);
      expect(back.toWindow().to, quarter.to);
    });
  });
}
