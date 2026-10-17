import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:drift/drift.dart' hide isNull;

import '../item_stock/item_common.dart'
    show itemOptions, itemScope, itemsById, kItemFilterId, selectedItemId;
import '../transaction/transaction_common.dart';
import 'sp_orders.dart' show purchaseOrderStatusLabel, salesOrderStatusLabel;

/// **Sale/Purchase Order Item** — every line on a sales order or purchase
/// order in the window, grouped by item.
///
/// Answers "how much of this item have we promised to customers or ordered from
/// suppliers" without touching actual stock or revenue figures.
const ReportSpec spOrderItemsSpec = ReportSpec(
  id: 'sp_order_items',
  title: 'Sale/Purchase Order Item',
  category: 'S/P Order',
  groupBy: ReportGroupBy.item,
  sort: ReportSort(columnKey: 'date'),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kItemFilterId,
      label: 'Item',
      value: null,
      hint: 'Every item',
    ),
  ],
  columns: [
    ReportColumn(key: 'item', label: 'Item', flex: 3, emphasise: true),
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(key: 'number', label: 'Order No.', emphasise: true),
    ReportColumn(key: 'type', label: 'Type', flex: 2),
    ReportColumn(key: 'party', label: 'Party', flex: 2),
    ReportColumn(key: 'status', label: 'Status'),
    ReportColumn(key: 'qty', label: 'Qty', kind: ReportValueKind.quantity),
    ReportColumn(
      key: 'rate',
      label: 'Rate',
      kind: ReportValueKind.rate,
      wideOnly: true,
    ),
    ReportColumn(
      key: 'taxable',
      label: 'Taxable',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(
      key: 'total',
      label: 'Line total',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
  ],
  footnote:
      'Line items from sales orders and purchase orders in the period, '
      'grouped by item. Orders do not move stock or affect the P&L until '
      'converted into an invoice or bill.',
);

const ReportDefinition spOrderItems = ReportDefinition(
  spec: spOrderItemsSpec,
  source: CallbackReportSource(
    sourceId: 'sp_order_items',
    query: spOrderItemsRows,
    options: itemOptions,
  ),
);

Future<List<ReportRow>> spOrderItemsRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selectedItem = selectedItemId(filters);

  final sLines = db.salesInvoiceItems;
  final sDocs = db.salesInvoices;
  final sQuery =
      db.select(sLines).join([
          innerJoin(sDocs, sDocs.id.equalsExp(sLines.invoiceId)),
        ])
        ..where(
          liveSalesIn(window, firmId, sDocs, docTypes: const ['sales_order']) &
              sLines.isDeleted.equals(false) &
              itemScope(sLines.itemId, selectedItem),
        )
        ..orderBy([
          OrderingTerm.asc(sDocs.invoiceDate),
          OrderingTerm.asc(sDocs.number),
          OrderingTerm.asc(sLines.sortOrder),
        ]);

  final pLines = db.purchaseBillItems;
  final pDocs = db.purchaseBills;
  final pQuery =
      db.select(pLines).join([
          innerJoin(pDocs, pDocs.id.equalsExp(pLines.billId)),
        ])
        ..where(
          livePurchasesIn(
                window,
                firmId,
                pDocs,
                docTypes: const ['purchase_order'],
              ) &
              pLines.isDeleted.equals(false) &
              itemScope(pLines.itemId, selectedItem),
        )
        ..orderBy([
          OrderingTerm.asc(pDocs.billDate),
          OrderingTerm.asc(pDocs.number),
          OrderingTerm.asc(pLines.sortOrder),
        ]);

  final sResults = await sQuery.get();
  final pResults = await pQuery.get();

  if (sResults.isEmpty && pResults.isEmpty) return const [];

  final itemIds = <String>{
    for (final r in sResults)
      if (r.readTable(sLines).itemId != null) r.readTable(sLines).itemId!,
    for (final r in pResults)
      if (r.readTable(pLines).itemId != null) r.readTable(pLines).itemId!,
  };
  final itemsMap = await itemsById(db, firmId, itemIds.toList());

  final rows = <ReportRow>[];
  for (final joined in sResults) {
    final line = joined.readTable(sLines);
    final doc = joined.readTable(sDocs);
    final itemName = (line.itemId != null && itemsMap.containsKey(line.itemId))
        ? itemsMap[line.itemId]!.name
        : line.name;
    rows.add(
      ReportRow({
        'item': itemName,
        'date': doc.invoiceDate,
        'number': doc.number,
        'type': docTypeLabel(doc.docType),
        'party': (doc.partyName ?? '').trim().isEmpty
            ? '—'
            : doc.partyName!.trim(),
        'status': salesOrderStatusLabel(doc),
        'qty': dec(line.quantity),
        'rate': dec(line.rate),
        'taxable': dec(line.taxableValue),
        'total': dec(line.total),
      }, label: itemName),
    );
  }

  for (final joined in pResults) {
    final line = joined.readTable(pLines);
    final bill = joined.readTable(pDocs);
    final itemName = (line.itemId != null && itemsMap.containsKey(line.itemId))
        ? itemsMap[line.itemId]!.name
        : line.name;
    rows.add(
      ReportRow({
        'item': itemName,
        'date': bill.billDate,
        'number': bill.number,
        'type': docTypeLabel(bill.docType),
        'party': (bill.partyName ?? '').trim().isEmpty
            ? '—'
            : bill.partyName!.trim(),
        'status': purchaseOrderStatusLabel(bill),
        'qty': dec(line.quantity),
        'rate': dec(line.rate),
        'taxable': dec(line.taxableValue),
        'total': dec(line.total),
      }, label: itemName),
    );
  }

  return rows;
}
