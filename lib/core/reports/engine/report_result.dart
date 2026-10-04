import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';

import '../../utils/formatters.dart';
import '../../utils/money.dart';
import '../spec/report_spec.dart';
import '../window/report_window.dart';

/// One row of a report.
///
/// Values are `Decimal` wherever they are numbers and `String` wherever they
/// are not. That is the whole point: a report that carries its money as
/// `double` has already lost the last paisa by the time it is summed, and the
/// grand total will be off by a figure nobody can explain.
///
/// `negate`d columns store the source's sign; the renderer and the totals both
/// read them through [value], which applies the flip exactly once. Reading a
/// negated column's raw map entry instead is the bug this accessor exists to
/// make impossible to write twice.
@immutable
class ReportRow {
  const ReportRow(this.cells, {this.label});

  final Map<String, Object?> cells;

  /// What identifies this row when it is rendered as a card on a narrow screen
  /// and appears as a group name when it is grouped. Null for an unnamed row,
  /// which renders its own identifying column instead.
  final String? label;

  /// The cell for [column], with [ReportColumn.negate] applied.
  ///
  /// Returns `Decimal.zero` for a missing or non-numeric cell rather than
  /// throwing: a report with an optional column that is null on some rows must
  /// still total. The *declared* columns are checked by `assertIntegrity`,
  /// which is where a missing key is an error rather than a silent zero.
  Decimal number(ReportColumn column) {
    final raw = cells[column.key];
    if (raw is Decimal) return column.negate ? -raw : raw;
    if (raw is num) {
      final d = Money.of(raw);
      return column.negate ? -d : d;
    }
    if (raw is String) {
      final parsed = Money.tryParse(raw);
      if (parsed != null) return column.negate ? -parsed : parsed;
    }
    return Decimal.zero;
  }

  /// The cell as it should be displayed, as text.
  String text(ReportColumn column) {
    final raw = cells[column.key];
    if (raw == null) return '';
    if (raw is Decimal) return formatNumber(raw, column);
    if (raw is num) return formatNumber(Money.of(raw), column);
    if (raw is DateTime) {
      return '${raw.day.toString().padLeft(2, '0')}-'
          '${raw.month.toString().padLeft(2, '0')}-${raw.year}';
    }
    final s = raw.toString();
    if (column.negate) {
      final parsed = Money.tryParse(s);
      if (parsed != null) return formatNumber(-parsed, column);
    }
    return s;
  }

  /// The cell as an export-ready string: a number is a plain grouped figure
  /// with no currency symbol, so a spreadsheet can sum the column.
  String export(ReportColumn column) {
    final raw = cells[column.key];
    if (raw == null) return '';
    if (raw is Decimal) return exportNumber(number(column));
    if (raw is num) return exportNumber(number(column));
    if (raw is DateTime) {
      return '${raw.year.toString().padLeft(4, '0')}-'
          '${raw.month.toString().padLeft(2, '0')}-'
          '${raw.day.toString().padLeft(2, '0')}';
    }
    return raw.toString();
  }

  static String formatNumber(Decimal value, ReportColumn column) {
    switch (column.kind) {
      case ReportValueKind.money:
        return Formatters.money(value);
      case ReportValueKind.percent:
        return '${Money.round2(value)}%';
      case ReportValueKind.rate:
        return Money.roundTo(value, places: 2).toString();
      case ReportValueKind.quantity:
      case ReportValueKind.count:
      case ReportValueKind.running:
        return Money.roundTo(value, places: 3).toString();
      case ReportValueKind.date:
      case ReportValueKind.text:
        return value.toString();
    }
  }

  /// A number as a spreadsheet reads it: a plain grouped-free figure, always
  /// two decimals, never a currency symbol.
  ///
  /// The two decimals are load-bearing. `Decimal.round(scale: 2)` returns the
  /// value **unchanged when its own scale is already ≤ 2** — `Decimal.fromInt(100)`
  /// round-trips as "100", not "100.00" — so a column would print a mix of
  /// "100" and "100.50" and a spreadsheet would read the first as text.
  /// `toStringAsFixed` pads, which is what `Formatters.money` does for the same
  /// reason.
  static String exportNumber(Decimal value) =>
      value.round(scale: 2).toStringAsFixed(2);
}

/// A group of rows plus its subtotal.
///
/// [cells] is null for a plain ungrouped report's single implicit group. The
/// engine always produces one structure, so the renderer has one code path.
@immutable
class ReportGroup {
  const ReportGroup({
    required this.name,
    required this.rows,
    this.totals = const {},
    this.label,
  });

  final String name;
  final List<ReportRow> rows;

  /// The group's subtotal per summable column key. Null cells mean the subtotal
  /// is genuinely absent (a group with no money in it), not zero — the grand
  /// total must not invent a figure for it.
  final Map<String, Decimal> totals;

  /// The group's identifying detail (a party's phone number, an item's SKU).
  final String? label;

  Decimal totalFor(ReportColumn column) => totals[column.key] ?? Decimal.zero;
}

/// Everything a report screen needs, already grouped, sorted and totalled.
@immutable
class ReportResult {
  const ReportResult({
    required this.spec,
    required this.window,
    required this.groups,
    required this.grandTotals,
    this.count = 0,
    this.notes = const [],
  });

  final ReportSpec spec;
  final ReportWindow window;
  final List<ReportGroup> groups;

  /// One figure per summable column key across every group.
  final Map<String, Decimal> grandTotals;

  /// The number of *rows*, not the number of groups. The header says "47 rows",
  /// not "9 rows", and conflating the two is how a report hides that a group
  /// swallowed its members.
  final int count;

  /// Anything the source wants to say above the table. A Trial Balance that
  /// disagrees with the P&L puts the delta here rather than throwing — a CA
  /// seeing the number is the point.
  final List<String> notes;

  bool get isEmpty => groups.isEmpty;

  Iterable<ReportRow> get rows => groups.expand((g) => g.rows);

  Decimal grandTotalFor(ReportColumn column) =>
      grandTotals[column.key] ?? Decimal.zero;
}

/// A report's rows and the checks that say whether they can be believed.
///
/// [problems] is non-empty when the result failed [ReportIntegrity.assert], and
/// the screen shows it as a red banner rather than printing a total that does
/// not foot. **A report whose subtotals do not add up is worse than no report:**
/// the number looks authoritative and it is wrong.
@immutable
class ReportIntegrity {
  const ReportIntegrity(this.problems);

  const ReportIntegrity.clean() : problems = const <String>[];

  final List<String> problems;

  bool get isClean => problems.isEmpty;

  /// The first problem, for a single-line banner.
  String get headline => problems.isEmpty ? '' : problems.first;
}

/// The checks that decide whether a [ReportResult] can be shown as fact.
///
/// This is the highest-value piece in the reporting build, and it exists because
/// **nothing else in the codebase checks a total.** `report_repository` sums in
/// `double` and converts at the end; the ledger and the P&L are two independent
/// implementations that have silently disagreed before. Across 47 reports × 8
/// numeric columns, a wrong total is invisible to every other check in the
/// build.
///
/// Three invariants, all exact:
///
/// 1. **Group subtotals sum to the grand total**, and the rows sum to their own
///    subtotals. Compared in [Decimal], not within an epsilon. A report that
///    reconciles to the paisa is correct; one that reconciles "close enough" is
///    wrong somewhere it does not show.
/// 2. **Every declared column key is present in every row.** A source that
///    returns `{'amount': …}` for a spec that declares `netAmount` renders a
///    column of blanks that looks exactly like a business with no data.
/// 3. **No declared column is empty across every row** — the same failure one
///    step removed, and the most misleading of the three, because the column
///    exists, is correctly aligned, and is entirely blank.
///
/// A namespace rather than a method on `ReportResult`, so that "did anyone
/// check this?" has one answerable location.
extension ReportIntegrityChecks on ReportIntegrity {
  /// Assert [result] and return the problems found. Empty means it can be shown
  /// as fact; non-empty means the screen shows a banner and the totals are not
  /// to be trusted.
  static ReportIntegrity assertIntegrity(ReportResult result) {
    final problems = <String>[];
    final spec = result.spec;

    // 1. Column coverage. A key no row carries renders as a column of blanks,
    //    which is indistinguishable from a business with no data.
    final missing = <String, int>{};
    for (final row in result.rows) {
      for (final column in spec.columns) {
        if (!row.cells.containsKey(column.key)) {
          missing[column.key] = (missing[column.key] ?? 0) + 1;
        }
      }
    }
    final absent = missing.keys.toList()..sort();
    if (absent.isNotEmpty) {
      final count = missing.values.fold<int>(0, (a, b) => a + b);
      problems.add(
        '${spec.title}: ${absent.join(', ')} ${absent.length == 1 ? 'is' : 'are'} '
        'missing from $count ${count == 1 ? 'row' : 'rows'}',
      );
    }

    // 2. Subtotals against the total.
    for (final column in spec.columns) {
      if (!column.isSummable) continue;
      var fromGroups = Decimal.zero;
      var fromRows = Decimal.zero;
      for (final group in result.groups) {
        fromGroups += group.totalFor(column);
        for (final row in group.rows) {
          fromRows += row.number(column);
        }
      }
      final grand = result.grandTotalFor(column);
      if (fromGroups != grand) {
        problems.add(
          '${spec.title}: ${column.label} subtotals ($fromGroups) do not sum '
          'to the total ($grand)',
        );
      }
      if (fromRows != fromGroups) {
        problems.add(
          '${spec.title}: ${column.label} rows ($fromRows) do not sum to their '
          'own subtotals ($fromGroups)',
        );
      }
    }

    // 3. A declared column nothing ever filled. Not caught by (1) — every row
    //    *has* the key, it is just always null — and it is the most misleading
    //    case there is: a full column of blanks where figures should be.
    if (result.rows.isNotEmpty) {
      for (final column in spec.columns) {
        var filled = 0;
        for (final row in result.rows) {
          final value = row.cells[column.key];
          if (value != null && '$value'.isNotEmpty) filled++;
        }
        if (filled == 0) {
          problems.add(
            '${spec.title}: ${column.label} is declared but no row fills it',
          );
        }
      }
    }

    return ReportIntegrity(problems);
  }
}
