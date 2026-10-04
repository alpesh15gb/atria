import 'package:decimal/decimal.dart';

import '../spec/report_spec.dart';
import '../window/report_window.dart';
import 'report_result.dart';

/// Turns loose rows into a grouped, sorted, totalled [ReportResult].
///
/// Everything numeric happens in [Decimal]. That is not pedantry: a party
/// statement over 5,000 rows summed in `double` accumulates error, and the last
/// row of a running balance will not equal the sum of the columns above it — the
/// one thing a statement reader checks first.
///
/// [ReportRunner.fold] is the single place grouping, subtotalling, sorting and
/// grand-totalling happen. A report that computes its own subtotals is a report
/// that can disagree with its own total.
class ReportRunner {
  const ReportRunner();

  /// Build a result from rows already carrying their group name in
  /// [groupKeyOf].
  ///
  /// Pass [groupKeyOf] as `null` for an ungrouped report: every row lands in
  /// one group whose subtotal is the grand total, so the renderer has one code
  /// path and an ungrouped table cannot be missing its own total row.
  ReportResult fold({
    required ReportSpec spec,
    required ReportWindow window,
    required List<ReportRow> rows,
    String Function(ReportRow row)? groupKeyOf,
    String Function(ReportRow row)? groupLabelOf,
    String Function(ReportRow row)? sortKeyOf,
    List<String> notes = const [],
  }) {
    final summable = spec.columns.where((c) => c.isSummable).toList();
    final groupBy = groupKeyOf;

    // 1. Bucket. Insertion-ordered so a report keeps its source's order unless
    //    it asked for a sort — a chronological ledger must not be alphabetised
    //    because someone added a group-by.
    final order = <String>[];
    final buckets = <String, List<ReportRow>>{};
    for (final row in rows) {
      final key = groupBy == null ? '' : groupKeyOf!(row);
      final bucket = buckets[key];
      if (bucket == null) {
        buckets[key] = [row];
        order.add(key);
      } else {
        bucket.add(row);
      }
    }

    // 2. Sort, if asked. Only within a group: a report that sorts globally
    //    reorders the groups too, which reads as random when the groups are
    //    months.
    final sort = spec.sort;
    if (sort != null && sort.columnKey.isNotEmpty) {
      final column = _columnFor(spec, sort.columnKey);
      for (final bucket in buckets.values) {
        // A source's own sort key wins when it has one — an HSN code sorts as
        // text, and 12A must come before 12B, not between 129 and 130.
        if (sortKeyOf != null) {
          bucket.sort((a, b) {
            final c = _compareText(sortKeyOf(a), sortKeyOf(b));
            return sort.descending ? -c : c;
          });
        } else if (column != null && column.kind == ReportValueKind.date) {
          // A date column sorts **chronologically**. `text()` renders it as
          // `dd-mm-yyyy`, and sorting that as text puts 02 May before 10
          // April — a sale register with April's invoice printed under May.
          // The cell is a DateTime, so it compares as one; anything else in
          // the cell falls back to its text so a source that pre-formatted its
          // dates still orders rather than throwing.
          final target = column;
          bucket.sort((a, b) {
            final av = a.cells[target.key];
            final bv = b.cells[target.key];
            final c = (av is DateTime && bv is DateTime)
                ? av.compareTo(bv)
                : _compareText(a.text(target), b.text(target));
            return sort.descending ? -c : c;
          });
        } else if (column == null || column.kind == ReportValueKind.text) {
          final target = column;
          bucket.sort((a, b) {
            final c = target == null
                ? 0
                : _compareText(a.text(target), b.text(target));
            return sort.descending ? -c : c;
          });
        } else {
          final target = column;
          bucket.sort((a, b) {
            final c = a.number(target).compareTo(b.number(target));
            return sort.descending ? -c : c;
          });
        }
      }
    }

    // 3. Subtotal each group.
    final groups = <ReportGroup>[];
    for (final key in order) {
      final bucket = buckets[key]!;
      final totals = <String, Decimal>{};
      for (final column in summable) {
        // Summing the group as the reader will see it — negated columns
        // included, or a purchase-return group totals the wrong way round.
        var sum = Decimal.zero;
        for (final row in bucket) {
          sum += row.number(column);
        }
        totals[column.key] = sum;
      }
      groups.add(
        ReportGroup(
          name: key,
          label: groupLabelOf == null || bucket.isEmpty
              ? null
              : groupLabelOf(bucket.first),
          rows: bucket,
          totals: totals,
        ),
      );
    }

    // 4. Grand total. Summed from the *groups*, never from the rows: if the
    //    group subtotals are wrong, the total must be wrong in the same way and
    //    the integrity check will say so. Summing the rows here would produce a
    //    total that disagrees with the table below it and hide the fault.
    final grandTotals = <String, Decimal>{};
    for (final column in summable) {
      var sum = Decimal.zero;
      for (final group in groups) {
        sum += group.totalFor(column);
      }
      grandTotals[column.key] = sum;
    }

    return ReportResult(
      spec: spec,
      window: window,
      groups: groups,
      grandTotals: grandTotals,
      count: rows.length,
      notes: notes,
    );
  }

  /// The rows a report actually shows, flattened for the count on the header.
  static ReportColumn? _columnFor(ReportSpec spec, String key) {
    for (final column in spec.columns) {
      if (column.key == key) return column;
    }
    return null;
  }

  static int _compareText(String? a, String? b) => (a ?? '').compareTo(b ?? '');
}
