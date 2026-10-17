import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import 'gst_common.dart';

/// **Sale Summary By HSN** — outward supply, rate-wise, under each HSN/SAC.
///
/// This is the annexure GSTR-1's Table 12 is read from: every sale in the
/// period, collapsed to one row per HSN and tax rate, with the quantity sold
/// and the taxable value at that rate.
///
/// **One row per HSN *and* rate**, which is the whole report. A reader who wants
/// "how much cement did I sell" opens the item report; this answers "what do I
/// file under 2523 at 18%", and the same code at two rates is two rows —
/// because the portal files it that way, and a single row carrying a taxable
/// value against a rate that never applied to all of it is a rejected return.
///
/// **A credit note is negative.** It returns goods, so it reduces the taxable
/// value filed under that code and the tax charged on it. Summing it positive
/// would overstate outward supply — and the portal computes the liability from
/// this figure, so the overstatement is money.
///
/// **The rate is derived from the line's own tax, not from the item master.**
/// See [effectiveRateOf]. The master holds the rate for the *next* invoice.
const ReportSpec saleSummaryByHsnSpec = ReportSpec(
  id: 'sale_summary_by_hsn',
  title: 'Sale Summary By HSN',
  category: 'GST',
  // Ungrouped on purpose. The source already collapses every line into one row
  // per code-and-rate, so each row *is* its own group — grouping would add a
  // band above a single line and print its subtotal as the reader's real
  // figure. A report whose grouping carries no information is noise that looks
  // like structure.
  groupBy: ReportGroupBy.none,
  sort: ReportSort(columnKey: 'taxable', descending: true),
  columns: [
    ReportColumn(key: 'hsn', label: 'HSN/SAC', flex: 2, emphasise: true),
    ReportColumn(key: 'rate', label: 'Rate', kind: ReportValueKind.rate),
    ReportColumn(
      key: 'description',
      label: 'Description',
      flex: 3,
      wideOnly: true,
    ),
    ReportColumn(
      key: 'quantity',
      label: 'Quantity sold',
      kind: ReportValueKind.quantity,
    ),
    ReportColumn(key: 'unit', label: 'Unit'),
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
    ReportColumn(
      key: 'total',
      label: 'Total tax',
      kind: ReportValueKind.money,
      flex: 2,
    ),
  ],
  footnote:
      'Outward supplies only, rate-wise, as filed under GSTR-1 Table 12. A '
      'credit note reduces the taxable value and the tax under the same code. '
      'The rate is worked out from each line\'s own tax, so an inclusive line or '
      'a discount is filed at the rate actually charged. Lines with no HSN/SAC '
      'are grouped as "Not set" — the portal cannot file them until they are '
      'coded. Cancelled documents are excluded.',
);

const ReportDefinition saleSummaryByHsn = ReportDefinition(
  spec: saleSummaryByHsnSpec,
  source: CallbackReportSource(
    sourceId: 'sale_summary_by_hsn',
    query: saleSummaryByHsnRows,
    notes: _saleSummaryByHsnNotes,
  ),
);

/// One HSN-and-rate bucket, accumulated in [Decimal].
///
/// Mutable on purpose: every line in a filing period collapses into a handful of
/// buckets, and a per-line `Decimal` read is what keeps the total exact. The
/// quantity is a [Decimal] too — a firm selling in units and thousandths, or a
/// service billed in hours, does not round its outward supply.
class _HsnBucket {
  _HsnBucket(this.hsn, this.rate);

  final String hsn;
  final Decimal rate;

  var quantity = Decimal.zero;
  var taxable = Decimal.zero;
  var cgst = Decimal.zero;
  var sgst = Decimal.zero;
  var igst = Decimal.zero;
  var cess = Decimal.zero;

  /// The first description seen for the code, used as the row's label.
  String? description;
  String unit = 'pcs';

  Decimal get totalTax => cgst + sgst + igst + cess;
}

Future<List<ReportRow>> saleSummaryByHsnRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  // An unregistered firm has no Table 12 to file. Returning nothing here is the
  // honest answer; the spec's footnote explains the blank screen.
  if (!await firmIsGstRegistered(db, firmId)) return const [];

  // Lines, not document headers. The HSN lives on the line, and a single invoice
  // can carry three codes — summarising from the document would file all three
  // under whichever line happened to be read.
  // The documents first: they carry the status, the doc type (hence the sign)
  // and the date, and the lines carry none of it. Joining in SQL would put the
  // reporting rules inside a query string no test can read, and the sign is a
  // rule — so the join happens here, in a loop, where it can be asserted.
  final docs =
      await (db.select(db.salesInvoices)..where(
            (d) =>
                d.firmId.equals(firmId) &
                d.docType.isIn(kSalesDocTypes) &
                ReportFilters.isLive(status: d.status, isDeleted: d.isDeleted) &
                ReportFilters.within(d.invoiceDate, window),
          ))
          .get();
  if (docs.isEmpty) return const [];

  final lines =
      await (db.select(db.salesInvoiceItems)..where(
            (l) =>
                l.invoiceId.isIn(docs.map((d) => d.id)) &
                l.isDeleted.equals(false),
          ))
          .get();

  // The sign comes from the parent document, so a credit note reduces the
  // taxable value filed under its code rather than adding to it.
  final docSigns = <String, int>{
    for (final doc in docs) doc.id: signFor(doc.docType),
  };

  final buckets = <String, _HsnBucket>{};
  for (final line in lines) {
    final sign = docSigns[line.invoiceId] ?? 1;
    final rate = effectiveRateOf(
      taxableValue: line.taxableValue,
      cgst: line.cgst,
      sgst: line.sgst,
      igst: line.igst,
      cess: line.cessAmount,
    );
    final hsn = hsnOrUnset(line.hsn);
    // Keyed on the code *and* the rate: the same code at 5% and at 18% are two
    // rows of Table 12, and merging them produces a taxable value filed against
    // a rate that never applied to it.
    final key = '$hsn@${rateLabel(rate)}';
    final bucket = buckets.putIfAbsent(key, () => _HsnBucket(hsn, rate));
    bucket.quantity += dec(line.quantity) * Decimal.fromInt(sign);
    bucket.taxable += dec(line.taxableValue) * Decimal.fromInt(sign);
    bucket.cgst += dec(line.cgst) * Decimal.fromInt(sign);
    bucket.sgst += dec(line.sgst) * Decimal.fromInt(sign);
    bucket.igst += dec(line.igst) * Decimal.fromInt(sign);
    bucket.cess += dec(line.cessAmount) * Decimal.fromInt(sign);
    bucket.description ??= line.name;
    bucket.unit = line.unit;
  }

  final rows = <ReportRow>[];
  for (final bucket in buckets.values) {
    rows.add(
      ReportRow({
        'hsn': bucket.hsn,
        'rate': bucket.rate,
        'description': bucket.description ?? '',
        'quantity': bucket.quantity,
        'unit': bucket.unit,
        'taxable': bucket.taxable,
        'cgst': bucket.cgst,
        'sgst': bucket.sgst,
        'igst': bucket.igst,
        'cess': bucket.cess,
        'total': bucket.totalTax,
      }, label: '${bucket.hsn} @ ${rateLabel(bucket.rate)}%'),
    );
  }
  return rows;
}

/// A function, not a string — the source's `notes` slot is
/// `List<String> Function(ReportResult)`.
List<String> _saleSummaryByHsnNotes(ReportResult result) => [
  'Reads sales invoice lines. Cancelled documents, and anything in the '
      'recycle bin, are excluded — they are not outward supplies.',
];
