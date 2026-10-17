import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import '../transaction/transaction_common.dart';

/// **TCS Receivable** — tax collected at source, owed to the government.
///
/// Tax *collected from customers* rather than deducted for them: TCS is
/// charged on a large sale and remitted by the seller. So this report answers
/// "what did I collect that is not mine", which is a liability — unlike TDS
/// Receivable, which is a credit against what the firm owes.
///
/// It is the one report in the Taxes folder whose figures are **not** a mirror
/// of a purchase-side one, and the asymmetry is the reason to keep them apart:
/// they go on different lines of the return.
///
/// **Only documents that actually collected TCS**, because the remittance line
/// is the sum of what was collected and a document with none contributes zero.
/// Listing every invoice would make the total disagree with the return by every
/// exempt sale in the quarter.
///
/// **A credit note reverses** — it returns goods, so the tax collected on them
/// goes back.
const ReportSpec tcsReceivableSpec = ReportSpec(
  id: 'tcs_receivable',
  title: 'TCS Receivable',
  category: 'Taxes',
  // **No grouping.** This declared `ReportGroupBy.category`, but a TCS row is
  // date / number / party / gstin / rate / taxable / tcs — there is no
  // `category` cell, and the default key reader for a missing cell is the
  // literal string `"?"`. So every TCS invoice in the period collapsed into one
  // band headed `?` with a Subtotal beneath it. A register of individual
  // collections is a flat list, which is what `tds_payable` and `form_27eq`
  // already are.
  sort: ReportSort(columnKey: 'tcs', descending: true),
  columns: [
    ReportColumn(key: 'date', label: 'Date', flex: 2),
    ReportColumn(key: 'number', label: 'Invoice', flex: 2),
    ReportColumn(key: 'party', label: 'Customer', flex: 3, emphasise: true),
    ReportColumn(key: 'gstin', label: 'GSTIN', flex: 2),
    ReportColumn(key: 'rate', label: 'TCS rate', kind: ReportValueKind.rate),
    ReportColumn(
      key: 'taxable',
      label: 'Taxable value',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'tcs',
      label: 'TCS collected',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
  ],
  footnote:
      'Tax collected at source on your sales, which you hold and remit rather '
      'than keep — a liability, not a credit. Only invoices that actually '
      'collected TCS are listed, because this total is the remittance line of '
      'the return. A credit note reduces the period. Cancelled documents are '
      'excluded.',
);

const ReportDefinition tcsReceivable = ReportDefinition(
  spec: tcsReceivableSpec,
  source: CallbackReportSource(
    sourceId: 'tcs_receivable',
    query: tcsReceivableRows,
    notes: _tcsReceivableNotes,
  ),
);

Future<List<ReportRow>> tcsReceivableRows(
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
                ReportFilters.within(d.invoiceDate, window) &
                // Greater-than-zero rather than "not equal to 0": a stored
                // floating-point zero is the same absence of tax as the literal one,
                // and comparing a `real` for equality is how a four-paisa residue
                // ends up on a line of a government return.
                d.tcs.isBiggerThanValue(0),
          ))
          .get();
  if (docs.isEmpty) return const [];

  return [
    for (final doc in docs)
      ReportRow({
        'date': doc.invoiceDate,
        'number': doc.number,
        'party': (doc.partyName ?? '').trim().isEmpty
            ? 'Unknown customer'
            : doc.partyName!.trim(),
        'gstin': (doc.partyGstin ?? '').trim().isEmpty
            ? 'Not recorded'
            : doc.partyGstin!.trim(),
        'rate': dec(doc.tcsRate),
        'taxable': dec(doc.taxableValue),
        'tcs': dec(doc.tcs) * Decimal.fromInt(signFor(doc.docType)),
      }, label: doc.number),
  ];
}

/// A function, not a string — the source's `notes` slot is
/// `List<String> Function(ReportResult)`.
List<String> _tcsReceivableNotes(ReportResult result) => [
  'Reads sales invoices and credit notes in the window. Only documents that '
      'actually collected tax at source are listed.',
];
