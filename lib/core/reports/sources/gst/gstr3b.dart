import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

// `buildGstr3b` is the top-level function in the same library that declares
// `Gstr3bReport` and `Gstr3bInterState`. An import is enough; the prefix is
// not, and would obscure which of the two entry points is in use.
import '../../gst_return_builder.dart';
import 'gst_common.dart';

/// **GSTR-3B** — the monthly summary return.
///
/// **Every figure comes from [GstReturnBuilder.buildGstr3b], not from this file.**
/// The builder is the code that already computes 3.1(a), 3.1(b), 3.2, 4(A), 4(B)
/// and 5, and it is the same code the CA's filing is generated from. A summary
/// return is the one document in the library where a second implementation is a
/// liability rather than a convenience: if this screen and the portal JSON
/// disagree, the reader files whichever one they trust, and one of them is
/// wrong. So the report is a *presentation* of the builder's output — each row
/// carries the return's own table number, which is what makes it checkable
/// against the portal.
///
/// **Table 3.1(a) is the whole liability, so it is the emphasised column.** The
/// rows around it are inputs to it.
const ReportSpec gstr3bSpec = ReportSpec(
  id: 'gstr3b',
  title: 'GSTR 3B',
  category: 'GST',
  layout: ReportLayout.document,
  sort: ReportSort(columnKey: 'taxable', descending: true),
  columns: [
    ReportColumn(key: 'table', label: 'Table', flex: 2),
    ReportColumn(key: 'description', label: 'Description', flex: 4, emphasise: true),
    ReportColumn(
      key: 'taxable',
      label: 'Taxable value',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(key: 'igst', label: 'IGST', kind: ReportValueKind.money),
    ReportColumn(key: 'cgst', label: 'CGST', kind: ReportValueKind.money),
    ReportColumn(key: 'sgst', label: 'SGST', kind: ReportValueKind.money),
    ReportColumn(key: 'cess', label: 'Cess', kind: ReportValueKind.money),
    ReportColumn(
      key: 'total',
      label: 'Total tax',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
  ],
  footnote:
      'The monthly summary, read straight from GstReturnBuilder — the same '
      'figures the portal JSON is generated from. Table 3.1(a) is the outward '
      'liability; 3.1(b) zero-rated and 3.1(c) nil-rated carry value but no tax. '
      'Table 4 is input tax, and only the net of 4(A) less 4(B) is a credit. '
      'Table 5 is inward supplies on which no tax was charged. ITC is not '
      'available to an unregistered person and an unregistered firm has no 3B '
      'to file, so this report is empty for one.',
);

const ReportDefinition gstr3b = ReportDefinition(
  spec: gstr3bSpec,
  source: CallbackReportSource(
    sourceId: 'gstr3b',
    query: gstr3bRows,
    notes: _gstr3bNotes,
  ),
);

Future<List<ReportRow>> gstr3bRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  if (!await firmIsGstRegistered(db, firmId)) return const [];

  // A top-level function, not a method on the builder: `buildGstr3b` takes
  // `db` and `firmId` and nothing from the instance, and reaching for the
  // instance's `db` field here would work but would read as if the builder
  // carried state it does not.
  final report = await buildGstr3b(
    db,
    firmId,
    from: windowFrom(window),
    to: windowTo(window),
  );

  final rows = <ReportRow>[
    _row(
      table: '3.1(a)',
      description: 'Outward taxable supplies',
      taxable: report.outwardTaxable,
      igst: report.outwardIgst,
      cgst: report.outwardCgst,
      sgst: report.outwardSgst,
      cess: report.outwardCess,
    ),
    _row(
      table: '3.1(b)',
      description: 'Outward taxable supplies (zero rated)',
      taxable: report.zeroRated,
    ),
    _row(
      table: '3.1(c)',
      description: 'Other outward supplies (nil rated / exempt)',
      taxable: report.nilRated,
    ),
    _row(
      table: '3.1(d)',
      description: 'Inward supplies liable to reverse charge',
      taxable: Decimal.zero,
      cess: report.reverseChargeTax,
      total: report.reverseChargeTax,
    ),
  ];

  // 3.2 is the inter-state, unregistered breakdown of 3.1(a)'s value — a detail
  // of the row above, not an addition to it, so it is labelled as such.
  for (final entry in report.interStateByPos) {
    rows.add(_row(
      table: '3.2',
      description: 'Place of supply ${entry.pos} — unregistered',
      taxable: entry.taxableValue,
      igst: entry.igst,
    ));
  }

  rows.addAll([
    _row(
      table: '4(A)(1)',
      description: 'Import of goods',
      taxable: Decimal.zero,
      cess: report.itcImport,
      total: report.itcImport,
    ),
    _row(
      table: '4(A)(3)',
      description: 'Inward supplies liable to reverse charge',
      taxable: Decimal.zero,
      cess: report.itcReverseCharge,
      total: report.itcReverseCharge,
    ),
    _row(
      table: '4(A)(4)',
      description: 'Input from ISD',
      taxable: Decimal.zero,
      cess: report.itcInwardIsd,
      total: report.itcInwardIsd,
    ),
    _row(
      table: '4(A)(5)',
      description: 'All other ITC',
      taxable: Decimal.zero,
      cess: report.itcAllOther,
      total: report.itcAllOther,
    ),
    _row(
      table: '4(B)',
      description: 'ITC reversed — Rule 42/43 and others',
      taxable: Decimal.zero,
      cess: -report.itcReversed,
      total: -report.itcReversed,
    ),
    _row(
      table: 'Net ITC',
      description: 'Input tax credit available (4(A) less 4(B))',
      taxable: Decimal.zero,
      cess: report.netItc,
      total: report.netItc,
      emphasise: true,
    ),
    _row(
      table: '5',
      description: 'Inward supplies on which no tax is payable',
      taxable: report.inwardNilRated,
    ),
    _row(
      table: '5',
      description: 'Non-GST inward supplies',
      taxable: report.inwardNonGst,
    ),
  ]);

  return rows;
}

/// One line of the return, in the return's own shape.
///
/// **Every cell is always present**, including the zeros. `assertIntegrity`
/// fails a declared column nothing fills, and a summary return whose tax
/// columns are blank on the value-only rows is genuinely ambiguous: a reader
/// cannot tell "nil-rated, no tax" from "we did not compute it".
ReportRow _row({
  required String table,
  required String description,
  required Decimal taxable,
  // Nullable with a zero default resolved inside, rather than `= Decimal.zero`
  // as a parameter default: `Decimal.zero` is a `static final`, and a default
  // parameter value must be a constant expression. Twelve call sites read
  // "this table carries no tax" without spelling the zero out.
  Decimal? igst,
  Decimal? cgst,
  Decimal? sgst,
  Decimal? cess,
  Decimal? total,
  bool emphasise = false,
}) {
  final ig = igst ?? Decimal.zero;
  final cg = cgst ?? Decimal.zero;
  final sg = sgst ?? Decimal.zero;
  final ce = cess ?? Decimal.zero;
  return ReportRow({
      'table': table,
      'description': description,
      'taxable': taxable,
      'igst': ig,
      'cgst': cg,
      'sgst': sg,
      'cess': ce,
      'total': total ?? (ig + cg + sg + ce),
    }, label: '$table $description');
}

/// A function, not a string: the source's `notes` is
/// `List<String> Function(ReportResult)`, which is what lets a report say
/// something only its own rows can support.
List<String> _gstr3bNotes(ReportResult result) => [
      'Computed by GstReturnBuilder from live documents in the window. '
      'Cancelled and deleted documents are excluded upstream.',
    ];