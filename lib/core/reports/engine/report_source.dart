import 'package:decimal/decimal.dart';
// Not `show Value`: every predicate here is built from drift's expression
// operators (`|`, `&`, `notEquals`, `isBiggerOrEqualValue`) and those live on
// extension types that a narrowed import silently drops.
import 'package:drift/drift.dart' hide isNull;

import '../../database/app_database.dart';
import '../spec/report_spec.dart';
import '../window/report_window.dart';
import 'report_result.dart';

/// Everything a report needs to produce its rows.
///
/// A source is **the only layer in the reporting build that knows SQL.** The
/// renderer, the exports and the catalogue all speak [ReportRow], so a report
/// that has to be rewritten — and some will — touches its own file and nothing
/// else.
///
/// `build` receives the resolved [window] rather than computing one. Every
/// window in the app comes from `ReportWindow.resolve`, and a source that
/// computed its own would be free to end a quarter at the wall clock — the bug
/// that once re-ran every card on the reports screen on every rebuild.
abstract class ReportSource {
  const ReportSource();

  /// The catalogue id this source serves. A source whose id does not match its
  /// spec's is a wiring mistake the catalogue check catches.
  String get sourceId;

  /// The rows for [window] under [filters], already flattened.
  ///
  /// Implementations push the window into SQL. Materialising a firm's whole
  /// history and filtering in Dart is what today's reports do, and 47 of those
  /// on a 4GB Android device is a memory problem, not a slow one.
  Future<List<ReportRow>> build(
    AppDatabase db,
    String firmId,
    ReportWindow window,
    Map<String, Object?> filters,
  ) {
    throw UnimplementedError('$sourceId does not override build()');
  }

  /// What groups this source's rows, or null for a flat table.
  ///
  /// Defaults to the spec's group-by: a spec that declares
  /// [ReportGroupBy.month] groups by month without the source having to say so,
  /// and the value it reads is the row's `month` cell. A source whose grouping
  /// the spec does not declare is a spec bug, and the header would show a
  /// subtotal the reader cannot explain.
  String Function(ReportRow row)? groupKeyFor(ReportSpec spec) =>
      spec.isGrouped ? _groupKeyReaders[spec.groupBy] : null;

  /// The extra detail beside a group's name, where there is one.
  String Function(ReportRow row)? groupLabelFor(ReportSpec spec) => null;

  /// Sort key for a text column, where the source's raw order is the useful
  /// one (an HSN code sorts as text, not as a number).
  String Function(ReportRow row)? sortKeyFor(ReportSpec spec) => null;

  /// Anything the source wants to say above the table.
  ///
  /// Takes the **folded** result, not the raw rows, because the thing worth
  /// reporting is usually a disagreement the fold exposed — a Trial Balance that
  /// does not balance, a P&L whose two independent implementations differ. That
  /// is a number the reader must see, and it is the one case where throwing
  /// would be wrong: a CA looking at an unbalanced book needs the book, not an
  /// error page.
  List<String> Function(ReportResult result)? notesFor(ReportSpec spec) => null;

  /// The selectable values for one of this report's filters, read live.
  ///
  /// **Why a source supplies options at all**, when [ReportSpec.defaultFilters]
  /// could just have declared them. Because a spec is a `const`, holds no
  /// database handle, and is deliberately constructible in a test with no
  /// fixture. The *party list* cannot be `const` — it is the firm's, and it
  /// changes when somebody adds a customer. So the filter declares itself and
  /// the source answers it, and the two halves stay independently testable: a
  /// spec test checks the declaration, a source test checks the values against
  /// a real database.
  ///
  /// The default reads the declared options, so a report whose filter really is
  /// an enumeration (`paid | unpaid`) needs nothing here.
  Future<List<ReportFilterOption<Object?>>> optionsFor(
    AppDatabase db,
    String firmId,
    ReportSpec spec,
    String filterId,
  ) async {
    return spec.filterWithId(filterId)?.options ?? const [];
  }
}

/// A source built from a closure, for the reports that are one query and no
/// more.
///
/// Most of the 47 are this. Writing a class per report to wrap a single
/// `customSelect` is ceremony that hides which reports are actually hard.
class CallbackReportSource extends ReportSource {
  const CallbackReportSource({
    required this.sourceId,
    required this.query,
    this.groupKey,
    this.groupLabel,
    this.sortKey,
    this.notes,
    this.options,
  });

  @override
  final String sourceId;

  final Future<List<ReportRow>> Function(
    AppDatabase db,
    String firmId,
    ReportWindow window,
    Map<String, Object?> filters,
  )
  query;

  final String Function(ReportRow row)? groupKey;
  final String Function(ReportRow row)? groupLabel;
  final String Function(ReportRow row)? sortKey;
  final List<String> Function(ReportResult result)? notes;

  /// The live values for this report's filters, by filter id. A report with no
  /// dynamic filter omits it and the spec's own declared options stand.
  final Future<List<ReportFilterOption<Object?>>> Function(
    AppDatabase db,
    String firmId,
    ReportSpec spec,
    String filterId,
  )?
  options;

  @override
  Future<List<ReportRow>> build(
    AppDatabase db,
    String firmId,
    ReportWindow window,
    Map<String, Object?> filters,
  ) => query(db, firmId, window, filters);

  @override
  String Function(ReportRow row)? groupKeyFor(ReportSpec spec) =>
      groupKey ?? super.groupKeyFor(spec);

  @override
  String Function(ReportRow row)? groupLabelFor(ReportSpec spec) => groupLabel;

  @override
  String Function(ReportRow row)? sortKeyFor(ReportSpec spec) => sortKey;

  @override
  List<String> Function(ReportResult result)? notesFor(ReportSpec spec) =>
      notes;

  @override
  Future<List<ReportFilterOption<Object?>>> optionsFor(
    AppDatabase db,
    String firmId,
    ReportSpec spec,
    String filterId,
  ) =>
      options?.call(db, firmId, spec, filterId) ??
      super.optionsFor(db, firmId, spec, filterId);
}

/// The cell each [ReportGroupBy] reads its group name from.
///
/// A convention rather than a parameter because the alternative is nine sources
/// each naming the same cell differently, and a group-by that silently groups
/// everything under "" renders one subtotal labelled with nothing. A report that
/// groups by something not listed here overrides [ReportSource.groupKeyFor].
final Map<ReportGroupBy, String Function(ReportRow)> _groupKeyReaders = {
  ReportGroupBy.none: _never,
  ReportGroupBy.category: _read('category'),
  ReportGroupBy.party: _read('party'),
  ReportGroupBy.item: _read('item'),
  ReportGroupBy.date: _readDate('date'),
  ReportGroupBy.month: _readMonth('month'),
  ReportGroupBy.hsn: _read('hsn'),
  ReportGroupBy.state: _read('state'),
  ReportGroupBy.account: _read('account'),
};

String _never(ReportRow row) => '';

/// Reads [key] off a row as text.
///
/// A missing cell groups under `"?"` rather than `""`, because an empty group
/// heading and a row that is genuinely blank look identical on screen and the
/// reader cannot tell which they are looking at.
String Function(ReportRow) _read(String key) => (ReportRow row) {
  final value = row.cells[key];
  return value == null ? '?' : '$value';
};

/// Groups by whole day, so a source can hand over its `DateTime` column and
/// still get `30-04-2026` as the heading rather than `Apr 2026`.
String Function(ReportRow) _readDate(String key) => (ReportRow row) {
  final value = row.cells[key];
  if (value is DateTime) return dayKey(value);
  if (value == null && key != 'date') {
    final fallback = row.cells['date'];
    if (fallback is DateTime) return dayKey(fallback);
  }
  return _read(key)(row);
};

/// Groups by month. A source may pre-compute the label into [key], hand over a
/// `DateTime` under [key], or simply have the usual `date` column — and all
/// three give the same heading.
///
/// The fallback to `date` is not a convenience. The map above names a
/// *convention*, but `row.cells` is a literal lookup, and no source bothers to
/// duplicate a `DateTime` into a second `month` cell just to be groupable. So
/// `_readMonth('month')` against a report whose date lives in `date` found
/// nothing, fell through to the missing-cell marker, and grouped **every month
/// of the period under a single `?` heading** — one subtotal for April and one
/// for June, merged, and no error anywhere.
String Function(ReportRow) _readMonth(String key) => (ReportRow row) {
  final value = row.cells[key] ?? row.cells['date'];
  if (value is DateTime) return monthKey(value);
  if (value == null) return '?';
  return '$value';
};

/// `30-04-2026`.
String dayKey(DateTime when) =>
    '${when.day.toString().padLeft(2, '0')}-'
    '${when.month.toString().padLeft(2, '0')}-${when.year}';

/// "Apr 2026" — a month group name that reads as a month.
///
/// Not `DateTime.toString()`, which prints `2026-04-01 00:00:00.000`, and not
/// `yyyy-MM`, which sorts correctly but reads as a sort key to anyone who has
/// not internalised that months are words. It does **not** sort correctly,
/// though, which is why a report that groups by month also declares
/// [ReportSort] on its date column: the runner sorts *within* groups, so the
/// source's own order is what keeps April ahead of May.
String monthKey(DateTime when) => '${monthLabels[when.month - 1]} ${when.year}';

const List<String> monthLabels = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// The shared predicates every report source must apply.
///
/// **These are not conveniences.** Each one is a way a report silently includes
/// something it must not, and each has already been got wrong in this codebase:
///
/// - **Bounced cheques.** `not(equals('bounced'))` on a **null** status is
///   SQL-null, so it drops every cash and bank payment as well as keeping the
///   bounced one. It has to be `isNull() | not(equals(...))`.
/// - **Cancelled and soft-deleted are separate.** A document can be in the
///   recycle bin without being cancelled. Filtering one does not filter the
///   other.
/// - **Quotations, orders and delivery notes are not transactions.** They are
///   not money and not stock. Include them and the Trial Balance and the P&L
///   disagree by every pending quotation.
/// - **Taxable value, never grand total.** Reporting `grandTotal` puts output
///   tax into revenue, and input tax credit is not revenue either way.
class ReportFilters {
  const ReportFilters._();

  /// A cheque status expression that keeps cash, bank and cleared cheques and
  /// drops only the bounced ones.
  static Expression<bool> notBounced(Expression<String> chequeStatus) {
    return chequeStatus.isNull() |
        chequeStatus.equals(ReportFilters.bouncedCheque).not();
  }

  static const String bouncedCheque = 'bounced';

  /// Not soft-deleted. Applies to anything with `is_deleted`.
  static Expression<bool> notDeleted(Expression<bool> isDeleted) =>
      isDeleted.equals(false);

  /// Not cancelled. Applies to anything with a `status`.
  static Expression<bool> notCancelled(Expression<String> status) =>
      status.isNull() | status.equals('cancelled').not();

  /// Not cancelled **and** not soft-deleted — the pair, because doing one
  /// without the other is the mistake.
  static Expression<bool> isLive({
    Expression<String>? status,
    Expression<bool>? isDeleted,
  }) {
    if (status != null && isDeleted != null) {
      return notCancelled(status) & notDeleted(isDeleted);
    }
    if (status != null) return notCancelled(status);
    if (isDeleted != null) return notDeleted(isDeleted);
    throw ArgumentError('isLive needs a status or an isDeleted to work on');
  }

  /// Only the document types that are actual transactions.
  static const List<String> transactionalDocTypes = [
    'invoice',
    'debit_note',
    'credit_note',
  ];

  /// The purchase-side equivalents.
  static const List<String> purchaseDocTypes = ['bill', 'debit_note'];

  /// The order in which a window's bounds are applied to a column.
  ///
  /// `from` is inclusive, `to` is inclusive at end-of-day. A null bound adds no
  /// clause at all rather than comparing against a sentinel date — an open-ended
  /// window is three of the app's five presets, and a sentinel would eventually
  /// exclude a real row.
  static Expression<bool> within(
    Expression<DateTime> column,
    ReportWindow window,
  ) {
    if (window.from != null && window.to != null) {
      return column.isBiggerOrEqualValue(window.from!) &
          column.isSmallerOrEqualValue(window.to!);
    }
    if (window.from != null) return column.isBiggerOrEqualValue(window.from!);
    if (window.to != null) return column.isSmallerOrEqualValue(window.to!);
    return const Constant(true);
  }

  /// Zero as a Decimal, for a source building a running total.
  static Decimal get zero => Decimal.zero;
}
