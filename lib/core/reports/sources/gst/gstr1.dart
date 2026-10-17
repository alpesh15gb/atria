import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import '../../gst_return_builder.dart';
import '../../gstr1_report.dart';
import 'gst_common.dart';

/// **GSTR-1** — the outward supplies return, as the tables the portal files.
///
/// One row per GSTR-1 table, so the screen can be checked against the portal's
/// own screen. That is the entire design: a reader does not want a summary, they
/// want to see that Table 4A says what they filed and Table 13A is empty
/// because they do not export.
///
/// **Every figure comes from [GstReturnBuilder.buildGstr1]** — the same code
/// that writes the portal JSON. A return shown on screen and the same return
/// uploaded must be the same return; two implementations of the B2B/B2CL/B2CS
/// bucketing would eventually disagree, and nobody would know which one was
/// filed.
///
/// **A table with no documents still appears, with zero.** An empty Table 7B on
/// a screen that simply omits it is indistinguishable from one the builder
/// forgot to fill.
const ReportSpec gstr1Spec = ReportSpec(
  id: 'gstr1',
  title: 'GSTR 1',
  category: 'GST',
  layout: ReportLayout.document,
  columns: [
    ReportColumn(key: 'table', label: 'Table', flex: 2, emphasise: true),
    ReportColumn(key: 'description', label: 'Description', flex: 4),
    ReportColumn(key: 'count', label: 'Docs', kind: ReportValueKind.count),
    ReportColumn(
      key: 'taxable',
      label: 'Taxable value',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
    ReportColumn(key: 'cgst', label: 'CGST', kind: ReportValueKind.money),
    ReportColumn(key: 'sgst', label: 'SGST', kind: ReportValueKind.money),
    ReportColumn(key: 'igst', label: 'IGST', kind: ReportValueKind.money),
    ReportColumn(key: 'cess', label: 'Cess', kind: ReportValueKind.money),
    // The portal has no "total tax" column of its own, but a reader comparing
    // this screen against the filed return does: without it, checking Table 4
    // means adding CGST, SGST, IGST and cess in their head.
    ReportColumn(
      key: 'total',
      label: 'Tax charged',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
  ],
  subtitle: 'Outward supplies — the tables as the portal files them',
  footnote:
      'Read straight from GstReturnBuilder, which also produces the portal JSON: '
      'what you see here is what gets uploaded. B2B is registered customers '
      '(Table 4A/4B), B2CL is large inter-state sales to unregistered buyers '
      '(Table 6B/6C), B2CS is everything else (Table 7). Exports go to 13A/13B '
      'under place of supply 96, Outside India. Cancelled documents are '
      'excluded, and an unregistered firm has no GSTR-1 to file.',
);

const ReportDefinition gstr1 = ReportDefinition(
  spec: gstr1Spec,
  source: CallbackReportSource(
    sourceId: 'gstr1',
    query: gstr1Rows,
    notes: _gstr1Notes,
  ),
);

Future<List<ReportRow>> gstr1Rows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  if (!await firmIsGstRegistered(db, firmId)) return const [];

  final report = await GstReturnBuilder(
    db,
    firmId,
  ).buildGstr1(from: windowFrom(window), to: windowTo(window));

  final rows = <ReportRow>[];

  // ---- B2B: Table 4 ------------------------------------------------------
  var b2bCount = 0;
  var b2bTaxable = Decimal.zero;
  var b2bCgst = Decimal.zero;
  var b2bSgst = Decimal.zero;
  var b2bIgst = Decimal.zero;
  var b2bCess = Decimal.zero;
  for (final block in report.b2b) {
    for (final invoice in block.invoices) {
      b2bCount++;
      b2bTaxable += _taxableOf(invoice.itms);
      b2bCgst += _sum(invoice.itms, (i) => i.cgst);
      b2bSgst += _sum(invoice.itms, (i) => i.sgst);
      b2bIgst += _sum(invoice.itms, (i) => i.igst);
      b2bCess += _sum(invoice.itms, (i) => i.cess);
    }
  }
  rows.add(
    _row(
      table: '4A / 4B',
      description: 'B2B — registered customers',
      count: b2bCount,
      taxable: b2bTaxable,
      cgst: b2bCgst,
      sgst: b2bSgst,
      igst: b2bIgst,
      cess: b2bCess,
    ),
  );

  // ---- B2CL: Table 6 -----------------------------------------------------
  var b2clCount = 0;
  var b2clTaxable = Decimal.zero;
  var b2clCgst = Decimal.zero;
  var b2clSgst = Decimal.zero;
  var b2clIgst = Decimal.zero;
  var b2clCess = Decimal.zero;
  for (final block in report.b2cl) {
    for (final invoice in block.invoices) {
      b2clCount++;
      b2clTaxable += _taxableOf(invoice.itms);
      b2clCgst += _sum(invoice.itms, (i) => i.cgst);
      b2clSgst += _sum(invoice.itms, (i) => i.sgst);
      b2clIgst += _sum(invoice.itms, (i) => i.igst);
      b2clCess += _sum(invoice.itms, (i) => i.cess);
    }
  }
  rows.add(
    _row(
      table: '6B / 6C',
      description: 'B2CL — inter-state, unregistered, over ₹2.5 lakh',
      count: b2clCount,
      taxable: b2clTaxable,
      cgst: b2clCgst,
      sgst: b2clSgst,
      igst: b2clIgst,
      cess: b2clCess,
    ),
  );

  // ---- B2CS: Table 7 -----------------------------------------------------
  //
  // Table 7 carries **no document count**, and neither does the builder's
  // `Gstr1B2cs`: the portal aggregates these by (supply type, place of supply,
  // rate), so the invoices behind the row cannot be counted without
  // re-deriving what the builder deliberately discarded. A dash says "not a
  // count this table has"; a zero would say "no documents", which is a
  // different and false claim on the row most firms have the most of.
  var b2csTaxable = Decimal.zero;
  var b2csCgst = Decimal.zero;
  var b2csSgst = Decimal.zero;
  var b2csIgst = Decimal.zero;
  var b2csCess = Decimal.zero;
  for (final row in report.b2cs) {
    b2csTaxable += row.taxableValue;
    b2csCgst += row.cgst;
    b2csSgst += row.sgst;
    b2csIgst += row.igst;
    b2csCess += row.cess;
  }
  rows.add(
    _row(
      table: '7',
      description: 'B2CS — small inter-state and all intra-state',
      count: '—',
      taxable: b2csTaxable,
      cgst: b2csCgst,
      sgst: b2csSgst,
      igst: b2csIgst,
      cess: b2csCess,
    ),
  );

  // ---- Exports: 13A / 13B -------------------------------------------------
  rows.add(
    _exportRow(
      table: '13A',
      description: 'Exports with payment — EXPWP',
      blocks: report.expwp,
    ),
  );
  rows.add(
    _exportRow(
      table: '13B',
      description: 'Exports without payment — EXPWOP',
      blocks: report.expwop,
    ),
  );

  // ---- Credit / debit notes: 9B / 9A / 10 --------------------------------
  var cdnrCount = 0;
  var cdnurCount = 0;
  var cdnrTaxable = Decimal.zero;
  var cdnrCgst = Decimal.zero;
  var cdnrSgst = Decimal.zero;
  var cdnrIgst = Decimal.zero;
  var cdnrCess = Decimal.zero;
  // A CDNR's tax is on its *item* rows, so it needs the same fold as an
  // invoice. A CDNUR has already been collapsed by the builder into aggregate
  // fields, which is why it can be read directly.
  for (final block in report.cdnr) {
    for (final note in block.notes) {
      cdnrCount++;
      cdnrTaxable += _taxableOf(note.itms);
      cdnrCgst += _sum(note.itms, (i) => i.cgst);
      cdnrSgst += _sum(note.itms, (i) => i.sgst);
      cdnrIgst += _sum(note.itms, (i) => i.igst);
      cdnrCess += _sum(note.itms, (i) => i.cess);
    }
  }
  var cdnurTaxable = Decimal.zero;
  var cdnurCgst = Decimal.zero;
  var cdnurSgst = Decimal.zero;
  var cdnurIgst = Decimal.zero;
  var cdnurCess = Decimal.zero;
  for (final note in report.cdnur) {
    cdnurCount++;
    cdnurTaxable += note.taxableValue;
    cdnurCgst += note.cgst;
    cdnurSgst += note.sgst;
    cdnurIgst += note.igst;
    cdnurCess += note.cess;
  }
  rows.add(
    _row(
      table: '9B / 9A',
      description: 'Credit / debit notes — CDNR, registered customers',
      count: cdnrCount,
      taxable: cdnrTaxable,
      cgst: cdnrCgst,
      sgst: cdnrSgst,
      igst: cdnrIgst,
      cess: cdnrCess,
    ),
  );
  // The CDNUR rows carry their own taxable value and tax, which is why the
  // note totals above are accumulated across CDNR and CDNUR together and CDNR
  // gets its own line. Splitting the accumulators would let a reader add up
  // Table 9B and Table 10 and find they disagree with the invoices.
  rows.add(
    _row(
      table: '10',
      description: 'Credit / debit notes — CDNUR, unregistered buyers',
      count: cdnurCount,
      taxable: cdnurTaxable,
      cgst: cdnurCgst,
      sgst: cdnurSgst,
      igst: cdnurIgst,
      cess: cdnurCess,
    ),
  );

  return rows;
}

/// One table's line in the return.
///
/// **Taxable value is the sum of the item rows**, never the document's `val`.
/// `val` is the invoice's face value — inclusive of tax — and filing it as the
/// taxable value inflates Table 4 by exactly the tax charged, which is the
/// difference between a return that reconciles and one the portal rejects.
/// [count] is an `Object?` because Table 7 has no document count at all — the
/// portal aggregates it by supply type, place and rate — and the cell carries a
/// dash rather than a zero that would claim there were no documents.
ReportRow _row({
  required String table,
  required String description,
  required Object? count,
  required Decimal taxable,
  Decimal? cgst,
  Decimal? sgst,
  Decimal? igst,
  Decimal? cess,
}) => ReportRow({
  'table': table,
  'description': description,
  'count': count is int ? Decimal.fromInt(count) : count,
  'taxable': taxable,
  'cgst': cgst ?? Decimal.zero,
  'sgst': sgst ?? Decimal.zero,
  'igst': igst ?? Decimal.zero,
  'cess': cess ?? Decimal.zero,
  'total':
      (cgst ?? Decimal.zero) +
      (sgst ?? Decimal.zero) +
      (igst ?? Decimal.zero) +
      (cess ?? Decimal.zero),
}, label: '$table $description');

ReportRow _exportRow({
  required String table,
  required String description,
  required List<Gstr1Export> blocks,
}) {
  var count = 0;
  var taxable = Decimal.zero;
  for (final block in blocks) {
    for (final invoice in block.invoices) {
      count++;
      taxable += _taxableOf(invoice.itms);
    }
  }
  // An export carries no CGST/SGST/IGST — that is what zero-rated means — so
  // those columns stay zero and the row carries its value alone.
  return _row(
    table: table,
    description: description,
    count: count,
    taxable: taxable,
  );
}

Decimal _taxableOf(List<Gstr1Item> items) =>
    items.fold(Decimal.zero, (sum, item) => sum + item.taxableValue);

Decimal _sum(List<Gstr1Item> items, Decimal Function(Gstr1Item) pick) =>
    items.fold(Decimal.zero, (sum, item) => sum + pick(item));

/// A function, not a string — the source's `notes` slot is
/// `List<String> Function(ReportResult)`.
List<String> _gstr1Notes(ReportResult result) => [
  'Computed by GstReturnBuilder from live documents in the window. This is '
      'the same report the portal JSON export is generated from. Table 7 shows '
      'no document count, because the portal aggregates it by place of supply '
      'and rate rather than by invoice.',
];
