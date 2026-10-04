import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../catalogue/report_catalogue.dart';
import '../engine/report_result.dart';
import '../spec/report_spec.dart';
import '../window/report_window.dart';

/// The window every report screen shares, and the one piece of state a report
/// screen owns.
///
/// A [StateProvider] rather than a hook-local value because **the window has to
/// survive navigation**: opening a party from a report, coming back, and
/// finding the period reset to This Month is the single most common complaint
/// about a reports screen. It lives above the screen for that reason.
final reportWindowProvider = StateProvider<ReportWindow>(
  (ref) => ReportWindow.resolve(ReportWindowPreset.thisFY),
);

/// A report's filters, keyed by `reportId`.
///
/// Also shared, for the same reason, and because two reports of the same family
/// (Party Statement and Party Report By Item) should open on the same party.
final reportFiltersProvider =
    StateProvider.family<Map<String, Object?>, String>((ref, _) => const {});

/// Runs a report and caches it by [ReportSpec.cacheKey].
///
/// **The cache key is the whole point.** Every input that changes the rows goes
/// into it — the report id, the window's own bounds, every filter, the sort
/// direction. Leave one out and the reader switches a filter, sees the previous
/// report's numbers, and has no way to tell anything is wrong.
///
/// `autoDispose` is deliberate. A report holds its whole result in memory, and
/// 46 cached reports at a few thousand rows each is the difference between a
/// report list that scrolls and one that gets killed by the OS on a 4GB phone.
/// Nothing survives navigation that way — see the `reportWindowProvider` note
/// for what *does* survive.
final reportResultProvider =
    FutureProvider.autoDispose.family<ReportResult, ReportQuery>((ref, query) async {
  final db = ref.watch(appDatabaseProvider);
  final firmId = ref.watch(activeFirmIdProvider);
  if (firmId == null) {
    // No firm means no report. Returning an empty result rather than throwing
    // means the screen shows its own empty state instead of a red error box for
    // something that is not an error.
    return ReportResult(
      spec: ReportCatalogue.byId(query.reportId)?.spec ??
          _unknownSpec(query.reportId),
      window: query.window,
      groups: const [],
      grandTotals: const {},
    );
  }
  final definition = ReportCatalogue.byId(query.reportId);
  if (definition == null) {
    throw StateError('No report is registered under "${query.reportId}".');
  }
  return definition.run(
    db,
    firmId,
    query.window,
    filters: query.filters,
  );
});

/// Everything that identifies one run of one report.
///
/// A value rather than three separate providers because they have to invalidate
/// *together*: watching a window and a filter separately means a screen can
/// rebuild with the new window and the old filter's numbers for one frame.
@immutable
class ReportQuery {
  const ReportQuery({
    required this.reportId,
    required this.window,
    this.filters = const {},
  });

  final String reportId;
  final ReportWindow window;
  final Map<String, Object?> filters;

  /// Two queries with the same key are the same run, which is what lets
  /// `FutureProvider.family` treat them as equal and reuse the cached result.
  String get cacheKey => _cacheKeyFor(reportId, window, filters);

  static String _cacheKeyFor(
    String reportId,
    ReportWindow window,
    Map<String, Object?> filters,
  ) {
    final parts = <String>[reportId, window.cacheKey];
    final keys = filters.keys.toList()..sort();
    for (final key in keys) {
      parts.add('$key=${filters[key]}');
    }
    return parts.join('|');
  }

  ReportQuery copyWith({
    ReportWindow? window,
    Map<String, Object?>? filters,
  }) {
    return ReportQuery(
      reportId: reportId,
      window: window ?? this.window,
      filters: filters ?? this.filters,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReportQuery &&
      other.reportId == reportId &&
      other.window == window &&
      _cacheKeyFor(other.reportId, other.window, other.filters) ==
          _cacheKeyFor(reportId, window, filters);

  @override
  int get hashCode => Object.hash(reportId, window, cacheKey);

  @override
  String toString() => 'ReportQuery($cacheKey)';
}

/// A stand-in spec for a report id nothing registered.
///
/// Only reachable when [reportWindowProvider] has no firm yet, which means there
/// is nothing to report *on*. It still needs a title, because the screen prints
/// one before it prints the empty state.
ReportSpec _unknownSpec(String id) => ReportSpec(
      id: id,
      title: id,
      category: 'Party',
      columns: const [],
    );