import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:drift/drift.dart' hide isNull;

import '../party/party_common.dart'
    show kPartyFilterId, partyOptions, partyScope, selectedPartyId;
import '../transaction/transaction_common.dart';

/// **Sale/Purchase Orders** — open and converted sales orders and purchase
/// orders in the window.
///
/// **Neither a sales order nor a purchase order is a transaction in the ledger.**
/// `kSalesDocTypes` and `kPurchaseDocTypes` exclude them on purpose so pending
/// orders never inflate revenue, payables, stock or the Trial Balance. They
/// live in their own report here so the shop can track what has been promised
/// to customers and ordered from suppliers, and which orders have already been
/// converted into invoices or bills.
const ReportSpec spOrdersSpec = ReportSpec(
  id: 'sp_orders',
  title: 'Sale/Purchase Orders',
  category: 'S/P Order',
  groupBy: ReportGroupBy.month,
  sort: ReportSort(columnKey: 'date'),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kPartyFilterId,
      label: 'Party',
      value: null,
      hint: 'Every party',
    ),
  ],
  columns: [
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(key: 'number', label: 'Order No.', emphasise: true),
    ReportColumn(key: 'type', label: 'Type', flex: 2),
    ReportColumn(key: 'party', label: 'Party', flex: 3),
    ReportColumn(
      key: 'dueDate',
      label: 'Due date',
      kind: ReportValueKind.date,
      wideOnly: true,
      optional: true,
    ),
    ReportColumn(key: 'status', label: 'Status'),
    ReportColumn(key: 'taxable', label: 'Taxable', kind: ReportValueKind.money),
    ReportColumn(key: 'tax', label: 'GST', kind: ReportValueKind.money),
    ReportColumn(
      key: 'total',
      label: 'Order total',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
  ],
  footnote:
      'Sales orders and purchase orders in the period. Orders are promises '
      'rather than completed sales or purchases, so they do not move stock or '
      'appear in the Profit & Loss or Trial Balance until converted into an '
      'invoice or bill. Cancelled and deleted orders are excluded.',
);

const ReportDefinition spOrders = ReportDefinition(
  spec: spOrdersSpec,
  source: CallbackReportSource(
    sourceId: 'sp_orders',
    query: spOrdersRows,
    options: partyOptions,
  ),
);

String salesOrderStatusLabel(SalesInvoiceEntity doc) {
  if (doc.convertedToInvoiceId != null || doc.status == 'converted') {
    return 'Converted';
  }
  return 'Open';
}

String purchaseOrderStatusLabel(PurchaseBillEntity bill) {
  if (bill.status == 'converted') return 'Converted';
  return 'Open';
}

Future<List<ReportRow>> spOrdersRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selectedParty = selectedPartyId(filters);

  final salesOrders =
      await (db.select(db.salesInvoices)
            ..where(
              (t) =>
                  liveSalesIn(
                    window,
                    firmId,
                    db.salesInvoices,
                    docTypes: const ['sales_order'],
                  ) &
                  partyScope(t.partyId, selectedParty),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.invoiceDate),
              (t) => OrderingTerm.asc(t.number),
            ]))
          .get();

  final purchaseOrders =
      await (db.select(db.purchaseBills)
            ..where(
              (t) =>
                  livePurchasesIn(
                    window,
                    firmId,
                    db.purchaseBills,
                    docTypes: const ['purchase_order'],
                  ) &
                  partyScope(t.partyId, selectedParty),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.billDate),
              (t) => OrderingTerm.asc(t.number),
            ]))
          .get();

  if (salesOrders.isEmpty && purchaseOrders.isEmpty) return const [];

  final partyIds = <String>{
    for (final s in salesOrders)
      if (s.partyId != null && (s.partyName ?? '').trim().isEmpty) s.partyId!,
    for (final p in purchaseOrders)
      if (p.partyId != null && (p.partyName ?? '').trim().isEmpty) p.partyId!,
  };
  final partyNames = <String, String>{};
  if (partyIds.isNotEmpty) {
    final rows = await (db.select(
      db.parties,
    )..where((p) => p.id.isIn(partyIds.toList()))).get();
    for (final p in rows) {
      partyNames[p.id] = p.name;
    }
  }

  final rows = <ReportRow>[];
  for (final doc in salesOrders) {
    final party = (doc.partyName ?? '').trim().isNotEmpty
        ? doc.partyName!.trim()
        : (partyNames[doc.partyId] ?? '—');
    rows.add(
      ReportRow({
        'date': doc.invoiceDate,
        'number': doc.number,
        'type': docTypeLabel(doc.docType),
        'party': party,
        'dueDate': doc.dueDate,
        'status': salesOrderStatusLabel(doc),
        'taxable': dec(doc.taxableValue),
        'tax': outputTaxOf(
          cgst: doc.cgst,
          sgst: doc.sgst,
          igst: doc.igst,
          cess: doc.cess,
        ),
        'total': dec(doc.grandTotal),
      }, label: doc.number),
    );
  }

  for (final bill in purchaseOrders) {
    final party = (bill.partyName ?? '').trim().isNotEmpty
        ? bill.partyName!.trim()
        : (partyNames[bill.partyId] ?? '—');
    rows.add(
      ReportRow({
        'date': bill.billDate,
        'number': bill.number,
        'type': docTypeLabel(bill.docType),
        'party': party,
        'dueDate': bill.dueDate,
        'status': purchaseOrderStatusLabel(bill),
        'taxable': dec(bill.taxableValue),
        'tax': outputTaxOf(
          cgst: bill.cgst,
          sgst: bill.sgst,
          igst: bill.igst,
          cess: bill.cess,
        ),
        'total': dec(bill.grandTotal),
      }, label: bill.number),
    );
  }

  rows.sort((a, b) {
    final ad = a.cells['date'] as DateTime;
    final bd = b.cells['date'] as DateTime;
    final cmp = ad.compareTo(bd);
    if (cmp != 0) return cmp;
    return '${a.cells['number']}'.compareTo('${b.cells['number']}');
  });

  return rows;
}
