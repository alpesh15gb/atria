import '../../../database/app_database.dart';
import '../../../database/repositories/repository_extensions.dart';
import '../../catalogue/report_catalogue.dart';
import '../../engine/report_result.dart';
import '../../engine/report_source.dart';
import '../../spec/report_spec.dart';
import '../../window/report_window.dart';

const gstr2PurchaseSpec = ReportSpec(
  id: 'gstr2_purchase',
  title: 'GSTR2 Purchase Report',
  category: 'GST',
  columns: [
    ReportColumn(key: 'gstin', label: 'GSTIN/UIN'),
    ReportColumn(key: 'party', label: 'Party Name', flex: 3),
    ReportColumn(key: 'type', label: 'Transaction Type'),
    ReportColumn(key: 'number', label: 'Invoice No.'),
    ReportColumn(
      key: 'date',
      label: 'Invoice Date',
      kind: ReportValueKind.date,
    ),
    ReportColumn(
      key: 'invoiceValue',
      label: 'Invoice Value',
      kind: ReportValueKind.rate,
    ),
    ReportColumn(key: 'rate', label: 'Rate', kind: ReportValueKind.percent),
    ReportColumn(
      key: 'cessRate',
      label: 'Cess Rate',
      kind: ReportValueKind.percent,
    ),
    ReportColumn(
      key: 'taxable',
      label: 'Taxable value',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'igst',
      label: 'Integrated Tax Amount',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'cgst',
      label: 'Central Tax Amount',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'sgst',
      label: 'State/UT Tax Amount',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'cess',
      label: 'Cess Amount',
      kind: ReportValueKind.money,
    ),
    ReportColumn(key: 'pos', label: 'Place of Supply'),
  ],
  footnote: 'Purchase-derived working paper in the Vyapar GSTR2 structure. Not a supplier-filed GST portal GSTR-2B statement. Invoice values repeat across item rows and are not summed. ITC requires eligibility and GSTR-2B review.',
);
const gstr2Purchase = ReportDefinition(
  spec: gstr2PurchaseSpec,
  source: CallbackReportSource(
    sourceId: 'gstr2_purchase',
    query: gstr2PurchaseRows,
  ),
);
Future<List<ReportRow>> gstr2PurchaseRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final repo = db.purchaseRepositoryFor(firmId);
  final rows = <ReportRow>[];
  for (final type in ['bill', 'debit_note']) {
    for (final bill in await repo.list(
      docType: type,
      from: window.from,
      to: window.to,
      limit: 1000000,
    )) {
      if (bill.status == 'cancelled') continue;
      final sign = type == 'debit_note' ? -1.0 : 1.0;
      for (final line in await repo.itemsFor(bill.id)) {
        rows.add(
          ReportRow({
            'gstin': bill.partyGstin ?? '',
            'party': bill.partyName ?? '',
            'type': type == 'bill' ? 'Purchase' : 'Purchase Return',
            'number': bill.supplierInvoiceNumber?.isNotEmpty == true
                ? bill.supplierInvoiceNumber!
                : bill.number,
            'date': bill.billDate,
            'invoiceValue': sign * bill.grandTotal,
            'rate': line.gstRate,
            'cessRate': line.cessRate,
            'taxable': sign * line.taxableValue,
            'igst': sign * line.igst,
            'cgst': sign * line.cgst,
            'sgst': sign * line.sgst,
            'cess': sign * line.cessAmount,
            'pos': bill.placeOfSupply ?? '',
            '_billId': bill.id,
            '_hsn': line.hsn ?? '',
            '_name': line.name,
            '_unit': line.unit,
            '_qty': sign * line.quantity,
            '_total': sign * line.total,
            '_rcm': bill.reverseCharge,
            '_interState': bill.isInterState,
            '_itc': bill.itcEligible,
          }),
        );
      }
    }
  }
  return rows;
}
