import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import 'gst_common.dart';

/// **SAC Report** — inward supply, rate-wise, under each HSN/SAC.
///
/// The purchase-side twin of Sale Summary By HSN: what came in, under which
/// code, at what rate, and the input tax on it. This is the annexure behind
/// GSTR-3B's Table 4, and the figure the portal compares against 2A when a
/// supplier's ITC is held back.
///
/// **Services are the point of this one.** A firm with no stock still files a
/// return, and every supply it makes is a SAC code rather than an HSN. So this
/// reads the same `hsn` column Sale Summary By HSN does — the master stores
/// "HSN for goods, SAC for services" in one field — and the two reports stay
/// consistent about which is which because they read the same place.
///
/// **A debit note is negative**, for the same reason a credit note is on the
/// sales side: it returns goods, and it cancels input tax rather than creating
/// it. Summing it positive would overstate ITC, and an overstated ITC is a
/// liability paid out of pocket.
const ReportSpec sacReportSpec = ReportSpec(
  id: 'sac_report',
  title: 'SAC Report',
  category: 'GST',
  // Ungrouped for the same reason as Sale Summary By HSN: the source has
  // already produced one row per code and rate, so a band above a single row
  // would print a subtotal as if it meant more than it does.
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
      label: 'Quantity bought',
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
      label: 'Input tax',
      kind: ReportValueKind.money,
      flex: 2,
    ),
  ],
  footnote:
      'Inward supplies only, rate-wise, as filed under GSTR-3B Table 4. A debit '
      'note reduces the taxable value and the input tax under the same code. '
      'The rate is worked out from each line\'s own tax. Lines with no HSN/SAC '
      'are grouped as "Not set". Cancelled bills are excluded.',
);

const ReportDefinition sacReport = ReportDefinition(
  spec: sacReportSpec,
  source: CallbackReportSource(
    sourceId: 'sac_report',
    query: sacReportRows,
    notes: _sacReportNotes,
  ),
);

class _SacBucket {
  _SacBucket(this.hsn, this.rate);

  final String hsn;
  final Decimal rate;

  var quantity = Decimal.zero;
  var taxable = Decimal.zero;
  var cgst = Decimal.zero;
  var sgst = Decimal.zero;
  var igst = Decimal.zero;
  var cess = Decimal.zero;

  String? description;
  String unit = 'pcs';

  Decimal get inputTax => cgst + sgst + igst + cess;
}

Future<List<ReportRow>> sacReportRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  if (!await firmIsGstRegistered(db, firmId)) return const [];

  // Documents first, for the same reason as the sales side: the status, the
  // type (hence the sign) and the date live on the bill, not on the line.
  final bills =
      await (db.select(db.purchaseBills)..where(
            (d) =>
                d.firmId.equals(firmId) &
                d.docType.isIn(kPurchaseDocTypes) &
                ReportFilters.isLive(status: d.status, isDeleted: d.isDeleted) &
                ReportFilters.within(d.billDate, window),
          ))
          .get();
  if (bills.isEmpty) return const [];

  final lines =
      await (db.select(db.purchaseBillItems)..where(
            (l) =>
                l.billId.isIn(bills.map((b) => b.id)) &
                l.isDeleted.equals(false),
          ))
          .get();

  final billSigns = <String, int>{
    for (final bill in bills) bill.id: signFor(bill.docType),
  };

  final buckets = <String, _SacBucket>{};
  for (final line in lines) {
    final sign = billSigns[line.billId] ?? 1;
    final rate = effectiveRateOf(
      taxableValue: line.taxableValue,
      cgst: line.cgst,
      sgst: line.sgst,
      igst: line.igst,
      cess: line.cessAmount,
    );
    final hsn = hsnOrUnset(line.hsn);
    final key = '$hsn@${rateLabel(rate)}';
    final bucket = buckets.putIfAbsent(key, () => _SacBucket(hsn, rate));
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
        'total': bucket.inputTax,
      }, label: '${bucket.hsn} @ ${rateLabel(bucket.rate)}%'),
    );
  }
  return rows;
}

/// A function, not a string — the source's `notes` slot is
/// `List<String> Function(ReportResult)`.
List<String> _sacReportNotes(ReportResult result) => [
  'Reads purchase bill lines. Cancelled bills, and anything in the recycle '
      'bin, are excluded — they are not inward supplies.',
];
