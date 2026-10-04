import 'package:flutter/foundation.dart';

import '../window/report_window.dart';

/// The declaration of a report: what it is called, what columns it has, how it
/// groups, and how it sorts.
///
/// This is deliberately **data, not behaviour**. A report that fits this shape
/// gets a table, grouping, subtotals, a pinned grand total, CSV, Excel, PDF and
/// print for free from one screen. A report that does not fit is one of nine
/// bespoke *documents* (P&L, Trial Balance, Balance Sheet, Cash flow, GSTR-1/3B/9,
/// Stock Detail, Day book) and says so with [ReportSpec.layout] instead of
/// being forced into a grid.
///
/// Nothing here reads the database. That separation is what lets a spec be
/// tested with hand-built rows and a source be tested with real ones.
enum ReportLayout {
  /// Rows in a table with optional grouping and subtotals.
  rows,

  /// A bespoke document with its own anatomy (a trial balance, a return).
  /// Rendered by a `ReportDocumentView` that still sits on the same toolbar,
  /// filters and export, so it inherits the same affordances.
  document,
}

/// How a column's value is written, sorted, totalled and exported.
///
/// The kind decides the *format*; it is not a hint. A `money` column is
/// right-aligned, tabular-figured, summed into the total row and exported as a
/// plain grouped number — a `text` column holding the string "₹1,00,000" would
/// sort lexically and export with the rupee sign in the cell.
enum ReportValueKind {
  text,
  money,

  /// A quantity. Not money: it takes no currency symbol, and it is summed
  /// separately from value so a report can show both without pretending a
  /// case and a rupee are the same measure.
  quantity,

  /// A per-unit price. Rounded for display but **not** summed — summing rates
  /// is meaningless and the total row must leave it blank.
  rate,

  /// A percentage. The `Of` column's default for anything whose value is a
  /// share of something. Never summed; a total of percentages is nonsense.
  percent,

  /// A count of documents. Summed like a quantity.
  count,

  date,

  /// A running balance: accumulated down the group, but excluded from the grand
  /// total, because the grand total of running balances is not a number anyone
  /// wants.
  running,
}

/// One column of a report.
///
/// [key] is the contract: every row must carry it, and the engine fails loudly
/// when one does not. A typo in a source's key would otherwise render as a blank
/// column that looks like a business with no data.
@immutable
class ReportColumn {
  const ReportColumn({
    required this.key,
    required this.label,
    this.kind = ReportValueKind.text,
    this.flex = 1,
    this.wideOnly = false,
    this.emphasise = false,
    this.colorize = false,
    this.negate = false,
    this.align = ReportColumnAlign.auto,
    this.totalLabel,
  });

  /// The key a row must carry this column's value under.
  final String key;

  final String label;
  final ReportValueKind kind;

  /// Relative width in the wide table. Money columns that carry six digits want
  /// more room than a status word.
  final int flex;

  /// Dropped on a narrow screen. The unit column of a stock report is the
  /// obvious case: on a phone the row already knows what it is.
  final bool wideOnly;

  /// Rendered in the strong style — the row's identifying figure.
  final bool emphasise;

  /// Negative values render in the error colour. A report where a negative is
  /// normal (a credit note, a return) sets this anyway: seeing the sign in red
  /// is information, not alarm.
  final bool colorize;

  /// The stored value is the opposite sign of the displayed one. A purchase
  /// return is stored negative and should read as a positive quantity of goods
  /// coming back; a purchase is stored as an outflow. Sources store what the
  /// transaction *was* and this flips it for the reader.
  final bool negate;

  /// Overrides the alignment the [kind] would otherwise pick. `auto` means "let
  /// the kind decide", which is right almost always.
  final ReportColumnAlign align;

  /// What to call this column in the grand-total row when the column is summed.
  /// A total of "Total" is fine; a total of "Amount" is noise.
  final String? totalLabel;

  /// The alignment this column renders at.
  ///
  /// Text is left, everything numeric is right, and that is not negotiable:
  /// a column of money that is left-aligned makes the decimal points ragged
  /// and hides a transposition.
  ReportColumnAlign get effectiveAlign => align == ReportColumnAlign.auto
      ? (kind == ReportValueKind.text || kind == ReportValueKind.date
            ? ReportColumnAlign.left
            : ReportColumnAlign.right)
      : align;

  /// Whether the grand-total row carries a figure for this column.
  ///
  /// Rates and percentages are excluded on purpose: "Total 18%" is not a
  /// number, and printing one invites the reader to add the column up.
  bool get isSummable =>
      kind == ReportValueKind.money ||
      kind == ReportValueKind.quantity ||
      kind == ReportValueKind.count;

  ReportColumn copyWith({
    String? key,
    String? label,
    ReportValueKind? kind,
    int? flex,
    bool? wideOnly,
    bool? emphasise,
    bool? colorize,
    bool? negate,
    ReportColumnAlign? align,
    String? totalLabel,
  }) {
    return ReportColumn(
      key: key ?? this.key,
      label: label ?? this.label,
      kind: kind ?? this.kind,
      flex: flex ?? this.flex,
      wideOnly: wideOnly ?? this.wideOnly,
      emphasise: emphasise ?? this.emphasise,
      colorize: colorize ?? this.colorize,
      negate: negate ?? this.negate,
      align: align ?? this.align,
      totalLabel: totalLabel ?? this.totalLabel,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReportColumn &&
      other.key == key &&
      other.label == label &&
      other.kind == kind &&
      other.flex == flex &&
      other.wideOnly == wideOnly &&
      other.emphasise == emphasise &&
      other.colorize == colorize &&
      other.negate == negate &&
      other.align == align &&
      other.totalLabel == totalLabel;

  @override
  int get hashCode => Object.hash(
    key,
    label,
    kind,
    flex,
    wideOnly,
    emphasise,
    colorize,
    negate,
    align,
    totalLabel,
  );
}

enum ReportColumnAlign { auto, left, right, center }

/// How a report's rows are grouped, and what the subtotal row is called.
enum ReportGroupBy {
  none('Rows'),

  /// "Subtotal" reads as an accounting term; in a list grouped by category the
  /// reader wants the category's own name.
  category('Subtotal'),

  party('Party total'),
  item('Item total'),
  date('Daily total'),
  month('Monthly total'),
  hsn('HSN total'),
  state('State total'),
  account('Account total');

  const ReportGroupBy(this.totalLabel);

  final String totalLabel;

  bool get isGrouped => this != ReportGroupBy.none;
}

/// One filter a report accepts. Declared here rather than built by each source
/// so the screen can render a filter it does not understand as disabled rather
/// than silently ignoring it.
@immutable
class ReportFilter<T> {
  const ReportFilter({
    required this.id,
    required this.label,
    required this.value,
    this.options = const [],
    this.hint,
  });

  final String id;
  final String label;
  final T value;

  /// The selectable values, when the filter is an enumeration. A filter with
  /// options is a dropdown; one without is a free-text or date entry.
  final List<ReportFilterOption<T>> options;

  final String? hint;
}

@immutable
class ReportFilterOption<T> {
  const ReportFilterOption({required this.value, required this.label, this.id});

  final T value;
  final String label;

  /// Overrides [key] for values whose `toString` is not stable or not
  /// meaningful — an object identity, say.
  final String? id;

  /// Stable identity for selection state. Defaults to the value's own string,
  /// which is fine for enums and dates and wrong for objects.
  String get key => id ?? value.toString();
}

/// One report's declaration.
///
/// [ReportSpec] is `@immutable` and holds no database handle, so a spec can be
/// constructed in a test with no fixture at all.
@immutable
class ReportSpec {
  const ReportSpec({
    required this.id,
    required this.title,
    required this.category,
    required this.columns,
    this.subtitle,
    this.layout = ReportLayout.rows,
    this.groupBy = ReportGroupBy.none,
    this.sort,
    this.defaultFilters = const [],
    this.supportsWide = true,
    this.docType,
    this.footnote,
  });

  /// The catalogue key. Stable, and the thing a route passes.
  final String id;

  final String title;

  /// One line under the title. For a bespoke document this is often the window
  /// and the basis ("Books vs Portal, 1 Apr 2026 – 31 Mar 2027").
  final String? subtitle;

  /// One of the nine menu categories, used to group the catalogue.
  final String category;

  final List<ReportColumn> columns;

  /// [ReportLayout.document] reports ignore [columns] for rendering but keep
  /// them for the export, so a trial balance exports the same rows it shows.
  final ReportLayout layout;

  final ReportGroupBy groupBy;

  /// Initial sort. Null keeps the source's order, which is usually the right
  /// one (chronological for a ledger, by value for a top-ten).
  final ReportSort? sort;

  final List<ReportFilter<Object?>> defaultFilters;

  /// False for a document whose width is fixed regardless of the window.
  final bool supportsWide;

  /// The document type behind a bespoke report, where one applies — used by the
  /// export to name the file and to open the right printer settings.
  final String? docType;

  /// A note printed under the table. Used for the things a reader must be told
  /// that are not visible in the numbers: what was excluded, and why.
  final String? footnote;

  bool get isGrouped => groupBy.isGrouped;

  /// Whether this report declares any filter at all.
  ///
  /// A getter rather than `defaultFilters.isNotEmpty` at the call site, because
  /// the screen asks it before every report and the answer decides whether a
  /// filter bar is drawn above the table.
  bool get hasFilters => defaultFilters.isNotEmpty;

  /// The filter declared under [id], or null.
  ///
  /// The lookup a dynamic filter needs. `defaultFilters` is a `const` list
  /// precisely so a spec can be built in a test with no database — which means
  /// its **options** cannot come from the firm's parties or items. The filter is
  /// declared here; its values are read at run time by the source.
  ReportFilter<Object?>? filterWithId(String id) {
    for (final filter in defaultFilters) {
      if (filter.id == id) return filter;
    }
    return null;
  }

  /// The columns a narrow screen shows.
  List<ReportColumn> get narrowColumns =>
      columns.where((c) => !c.wideOnly).toList(growable: false);

  ReportSpec copyWith({
    String? title,
    String? subtitle,
    ReportGroupBy? groupBy,
    ReportSort? sort,
    String? footnote,
  }) {
    return ReportSpec(
      id: id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      category: category,
      columns: columns,
      layout: layout,
      groupBy: groupBy ?? this.groupBy,
      sort: sort ?? this.sort,
      defaultFilters: defaultFilters,
      supportsWide: supportsWide,
      docType: docType,
      footnote: footnote ?? this.footnote,
    );
  }

  /// The key a report's cache is built from.
  ///
  /// Every input that changes the rows goes in here. Omit one and a reader
  /// switches a filter, sees the previous report's numbers, and has no way to
  /// tell that anything is wrong.
  String cacheKey(ReportWindow window, Map<String, Object?> filters) {
    final parts = <String>[id, window.cacheKey];
    final keys = filters.keys.toList()..sort();
    for (final key in keys) {
      parts.add('$key=${filters[key]}');
    }
    if (sort != null) parts.add(sort!.cacheKey);
    return parts.join('|');
  }
}

/// A sort, declared so two reports cannot disagree about whether `null` means
/// "ascending" or "unset".
@immutable
class ReportSort {
  const ReportSort({required this.columnKey, this.descending = false});

  final String columnKey;
  final bool descending;

  /// Sort key for a query's cache. Direction is part of it: the same column
  /// ascending and descending are two different reports.
  String get cacheKey => '$columnKey:${descending ? 'desc' : 'asc'}';
}
