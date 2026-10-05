import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import '../../gst_return_builder.dart';
import 'gst_common.dart';

/// **GSTR-9** — the annual return, Part II.
///
/// **Twelve monthly 3Bs plus the adjustments.** An annual return is not a
/// recomputation: it is the year's returns summed, with Tables 4, 6, 8 and 9
/// adjusted by whatever happened after each month was filed. This reads each
/// month's figures from [buildGstr3b] — the same code that produced them when
/// they were filed — and then applies the `gstr9_adjustments` table (schema v12)
/// on top.
///
/// **The adjustments are an addition *and* a reduction**, and the sign is the
/// row's `direction`, not the sign of `amount`. A reduction of ₹5,000 stored as
/// a positive ₹5,000 must come off the figure it adjusts; reading it as a
/// positive number would add ₹5,000 to a return the portal already has. The
/// direction column is applied here, in Dart, where a test can see it.
///
/// **Unregistered firms have no annual return either.** GSTR-9 is filed by a
/// registered person, and the ITC figures in Part II are the whole point of it.
const ReportSpec gstr9Spec = ReportSpec(
  id: 'gstr9',
  title: 'GSTR 9',
  category: 'GST',
  layout: ReportLayout.document,
  columns: [
    ReportColumn(key: 'table', label: 'Table', flex: 2, emphasise: true),
    ReportColumn(key: 'description', label: 'Description', flex: 5),
    ReportColumn(
      key: 'amount',
      label: 'Amount',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
  ],
  subtitle: 'Annual return, Part II — the year\'s returns, adjusted',
  footnote:
      'Part II only. Part I and Part III are the reconciliation tables the '
      'portal compares against the filed GSTR-1 and 3B, and they are not '
      'derivable from the books alone. Each figure is the sum of the monthly '
      'GSTR-3Bs for the financial year, taken from GstReturnBuilder — the code '
      'that filed them — plus the adjustments recorded against the year. '
      'Adjustments reduce a figure as readily as they add to it. The window '
      'should be the full financial year, 1 April to 31 March: a return filed '
      'on the wrong year is legally wrong however well the arithmetic adds up.',
);

const ReportDefinition gstr9 = ReportDefinition(
  spec: gstr9Spec,
  source: CallbackReportSource(
    sourceId: 'gstr9',
    query: gstr9Rows,
    notes: _gstr9Notes,
  ),
);

Future<List<ReportRow>> gstr9Rows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  if (!await firmIsGstRegistered(db, firmId)) return const [];

  // Every calendar month the window touches, each computed the way it was
  // filed. The first and last months are clamped to the window so a window
  // opened mid-month contributes that month and not a phantom day.
  //
  // The cap is not a limit on the report — it is a guard. Past 24 months this
  // is not an annual return whatever the arithmetic says, and the reader gets
  // the 24 months that exist rather than a table nobody can file.
  final from0 = windowFrom(window);
  final to0 = windowTo(window);
  final months = <({DateTime from, DateTime to})>[];
  var cursor = DateTime(from0.year, from0.month);
  while (!cursor.isAfter(to0) && months.length < 24) {
    final monthEnd = DateTime(cursor.year, cursor.month + 1, 0, 23, 59, 59);
    final from = cursor.isBefore(from0) ? from0 : cursor;
    final to = monthEnd.isAfter(to0) ? to0 : monthEnd;
    if (!from.isAfter(to)) months.add((from: from, to: to));
    cursor = DateTime(cursor.year, cursor.month + 1);
  }
  if (months.isEmpty) return const [];

  var outwardTaxable = Decimal.zero;
  var outwardTax = Decimal.zero;
  var zeroRated = Decimal.zero;
  var nilRated = Decimal.zero;
  var itcAvailable = Decimal.zero;
  var itcReversed = Decimal.zero;

  for (final month in months) {
    final report = await buildGstr3b(
      db,
      firmId,
      from: month.from,
      to: month.to,
    );
    outwardTaxable += report.outwardTaxable;
    outwardTax += report.outwardIgst +
        report.outwardCgst +
        report.outwardSgst +
        report.outwardCess;
    zeroRated += report.zeroRated;
    nilRated += report.nilRated;
    itcAvailable += report.itcAvailable;
    itcReversed += report.itcReversed;
  }

  final adjustments = await _adjustmentsFor(db, firmId, window);

  final rows = <ReportRow>[
    _row('4', 'Taxable value of outward supplies', outwardTaxable),
    _row(
      '4A',
      'Tax on outward supplies',
      outwardTax,
    ),
    _row('4B1', 'Taxable value of zero-rated supplies', zeroRated),
    _row('4B2', 'Taxable value of nil-rated / exempt supplies', nilRated),
    _row('4C', 'Tax on inward supplies liable to reverse charge', Decimal.zero),
  ];

  // Adjustments, then the net. The order is the point: Tables 4, 6, 8 and 9 of
  // GSTR-9 are each the filed figure *plus or minus* what was corrected after
  // the fact, and printing the corrected figure as its own row without the
  // adjustment beside it makes the difference unexplainable.
  for (final entry in adjustments.entries) {
    rows.add(_row(
      entry.key,
      'Adjustment — ${entry.value.description}',
      entry.value.amount,
    ));
  }

  rows.add(_row('6A', 'Input tax credit available', itcAvailable));
  rows.add(_row('6B', 'Input tax credit reversed', -itcReversed));
  rows.add(_row('6C', 'Net input tax credit available (6A less 6B)',
      itcAvailable - itcReversed));

  return rows;
}

/// The year's recorded adjustments, keyed by the table they correct.
///
/// [Gstr9Adjustment.direction] becomes the **sign**: `reduction` is stored as a
/// positive amount and comes off the figure, which is why the direction is read
/// rather than the amount's own sign. Two adjustments to the same table are
/// added — a correction made in November and another in March both count.
Future<Map<String, ({String description, Decimal amount})>> _adjustmentsFor(
  AppDatabase db,
  String firmId,
  ReportWindow window,
) async {
  final rows = await (db.select(db.gstr9Adjustments)
        ..where((a) =>
            a.firmId.equals(firmId) &
            a.financialYearStart.isBetweenValues(
              windowFrom(window),
              windowTo(window),
            )))
      .get();

  final byTable = <String, ({String description, Decimal amount})>{};
  for (final row in rows) {
    final magnitude = dec(row.amount);
    final signed = row.direction == 'reduction' ? -magnitude : magnitude;
    final existing = byTable[row.schedule];
    byTable[row.schedule] = (
      description: row.description,
      amount: (existing?.amount ?? Decimal.zero) + signed,
    );
  }
  return byTable;
}

ReportRow _row(String table, String description, Decimal amount) => ReportRow({
      'table': table,
      'description': description,
      'amount': amount,
    }, label: '$table $description');

/// A function, not a string — the source's `notes` slot is
/// `List<String> Function(ReportResult)`.
List<String> _gstr9Notes(ReportResult result) => [
      'Each monthly figure is recomputed by GstReturnBuilder over that month. '
      'Adjustments come from the GSTR-9 adjustments table for the financial year.',
    ];