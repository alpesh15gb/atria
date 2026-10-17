import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import '../transaction/transaction_common.dart';

/// **GST Rate Report** — the tax bands actually used, by rate.
///
/// The reader's question is "what rates am I charging, and what does each
/// bring in this period" — which is why this is a *period* report over real
/// documents rather than a list of the rates configured on the item master.
///
/// **The rates come from the documents, not the master.** An item's `gstRate`
/// is what the *next* invoice will use; a rate that was changed in June must
/// not erase five months of May at 18% from the return, and a rate still
/// configured but never sold is not part of what was filed. This is the same
/// rule `gst/gst_common.dart`'s [effectiveRateOf] exists to enforce, reached
/// from the opposite direction.
///
/// **Services and goods are counted apart**, because HSN and SAC have different
/// rate tables and a firm selling consulting at 18% and cement at 18% filed
/// them under different codes.
const ReportSpec gstRateReportSpec = ReportSpec(
  id: 'gst_rate_report',
  title: 'GST Rate Report',
  category: 'Taxes',
  sort: ReportSort(columnKey: 'taxable', descending: true),
  columns: [
    ReportColumn(
      key: 'rate',
      label: 'Rate',
      kind: ReportValueKind.rate,
      flex: 2,
      emphasise: true,
    ),
    ReportColumn(key: 'supply', label: 'Supply'),
    ReportColumn(
      key: 'documents',
      label: 'Documents',
      kind: ReportValueKind.count,
    ),
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
      key: 'tax',
      label: 'Tax collected',
      kind: ReportValueKind.money,
      flex: 2,
    ),
  ],
  footnote:
      'Rates are taken from the documents filed in this period, not from the '
      'rate configured on each item — that is the rate for the next invoice. '
      'A credit note reduces the taxable value and the tax on its own band. '
      'Nil-rated lines (0%) appear, because a report of "tax collected" that '
      'silently omits the exempt sales is a different document from the one the '
      'portal asks for.',
);

const ReportDefinition gstRateReport = ReportDefinition(
  spec: gstRateReportSpec,
  source: CallbackReportSource(
    sourceId: 'gst_rate_report',
    query: gstRateReportRows,
    notes: _gstRateReportNotes,
  ),
);

/// One (rate, goods-or-service) band, accumulated in [Decimal].
class _RateBand {
  var taxable = Decimal.zero;
  var cgst = Decimal.zero;
  var sgst = Decimal.zero;
  var igst = Decimal.zero;
  var cess = Decimal.zero;

  /// Documents counted separately from lines: an invoice with two lines at the
  /// same rate is one document, and "12 documents" would read as a document
  /// count that never existed if it counted lines.
  final documents = <String>{};

  Decimal get tax => cgst + sgst + igst + cess;
}

Future<List<ReportRow>> gstRateReportRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
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

  // The sign is the document's, so a credit note comes off its own band.
  final signs = <String, int>{
    for (final doc in docs) doc.id: signFor(doc.docType),
  };

  // Goods or service comes from the item the line points at. A line with no
  // item is goods by default — the item editor's own default — and saying so
  // in the label is better than filing a service silently under the goods
  // table.
  final itemKinds = <String, bool>{};
  final items =
      await (db.select(db.items)..where(
            (i) => i.id.isIn([
              for (final line in lines)
                if (line.itemId != null) line.itemId!,
            ]),
          ))
          .get();
  for (final item in items) {
    itemKinds[item.id] = item.isService;
  }

  final bands = <String, ({Decimal rate, bool service, _RateBand band})>{};
  for (final line in lines) {
    final sign = signs[line.invoiceId] ?? 1;
    final tax = dec(line.cgst) + dec(line.sgst) + dec(line.igst);
    final taxable = dec(line.taxableValue);
    // The rate the line was *actually* taxed at: derived from its own tax, not
    // read from the item. Same rule the HSN summary and the returns obey.
    final rate = taxable <= Decimal.zero
        ? Decimal.zero
        : (tax * Decimal.fromInt(100) / taxable)
              .toDecimal(scaleOnInfinitePrecision: 6)
              .round();
    final service = itemKinds[line.itemId] ?? false;
    final key = '${rate.toString()}|${service ? 'service' : 'goods'}';
    final band = bands
        .putIfAbsent(
          key,
          () => (rate: rate, service: service, band: _RateBand()),
        )
        .band;

    band.taxable += taxable * Decimal.fromInt(sign);
    band.cgst += dec(line.cgst) * Decimal.fromInt(sign);
    band.sgst += dec(line.sgst) * Decimal.fromInt(sign);
    band.igst += dec(line.igst) * Decimal.fromInt(sign);
    band.cess += dec(line.cessAmount) * Decimal.fromInt(sign);
    band.documents.add(line.invoiceId);
  }

  return [
    for (final entry in bands.values)
      ReportRow({
        'rate': entry.rate,
        'supply': entry.service ? 'Services (SAC)' : 'Goods (HSN)',
        'documents': Decimal.fromInt(entry.band.documents.length),
        'taxable': entry.band.taxable,
        'cgst': entry.band.cgst,
        'sgst': entry.band.sgst,
        'igst': entry.band.igst,
        'cess': entry.band.cess,
        'tax': entry.band.tax,
      }, label: '${entry.rate}% · ${entry.service ? 'Services' : 'Goods'}'),
  ];
}

/// A function, not a string — the source's `notes` slot is
/// `List<String> Function(ReportResult)`.
List<String> _gstRateReportNotes(ReportResult result) => [
  'Reads sales invoice lines in the window. Cancelled documents, and '
      'anything in the recycle bin, are excluded.',
];
