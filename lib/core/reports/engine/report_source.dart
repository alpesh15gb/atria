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
  /// Defaults to the spec's group-by when the source has nothing special to
  /// say. A source whose grouping the spec does not declare is a spec bug, and
  /// the header would show a subtotal the reader cannot explain.
  String Function(ReportRow row)? groupKeyFor(ReportSpec spec) => null;

  /// The extra detail beside a group's name, where there is one.
  String Function(ReportRow row)? groupLabelFor(ReportSpec spec) => null;

  /// Sort key for a text column, where the source's raw order is the useful
  /// one (an HSN code sorts as text, not as a number).
  String Function(ReportRow row)? sortKeyFor(ReportSpec spec) => null;
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

  @override
  String Function(ReportRow row)? groupKeyFor(ReportSpec spec) => groupKey;

  @override
  String Function(ReportRow row)? groupLabelFor(ReportSpec spec) => groupLabel;

  @override
  String Function(ReportRow row)? sortKeyFor(ReportSpec spec) => sortKey;
}

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
