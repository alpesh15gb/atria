import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import '../item_stock/item_common.dart'
    show
        itemCategoryNames,
        itemOptions,
        itemsById,
        kItemFilterId,
        selectedItemId;
import '../transaction/transaction_common.dart';
import 'expense_common.dart';

/// **Expense Item Report** — what the firm spent per item across purchase bills
/// and direct business expenses.
///
/// **`expenses.itemId` exists for this exact report** (schema v12): it allows
/// answering "what did I spend on this item" across purchase bills *and*
/// direct expenses without guessing from typed descriptions ("Petrol 20 Apr"
/// vs "Petrol, 20/4").
///
/// **Expenses with a null `itemId` still appear, grouped under their category.**
/// Dropping unlinked expenses would make the report understate total business
/// spending whenever an operator recorded an expense without picking a
/// catalogue item.
const ReportSpec expenseItemReportSpec = ReportSpec(
  id: 'expense_item',
  title: 'Expense Item Report',
  category: 'Expense',
  groupBy: ReportGroupBy.category,
  sort: ReportSort(columnKey: 'total', descending: true),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kItemFilterId,
      label: 'Item',
      value: null,
      hint: 'Every item & expense',
    ),
  ],
  columns: [
    ReportColumn(
      key: 'item',
      label: 'Item / Expense',
      flex: 3,
      emphasise: true,
    ),
    ReportColumn(key: 'category', label: 'Category', flex: 2),
    ReportColumn(
      key: 'qty',
      label: 'Purchase qty',
      kind: ReportValueKind.quantity,
    ),
    ReportColumn(
      key: 'purchase',
      label: 'Purchases',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(
      key: 'expense',
      label: 'Expenses',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(
      key: 'tax',
      label: 'GST',
      kind: ReportValueKind.money,
      wideOnly: true,
    ),
    ReportColumn(
      key: 'total',
      label: 'Total spent',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
  ],
  footnote:
      'Combines purchase bills (net of debit notes) and direct expenses '
      'linked via itemId, so spending on an item is complete regardless of '
      'how it was booked. Expenses recorded without an item link still appear '
      'under their expense category.',
);

const ReportDefinition expenseItemReport = ReportDefinition(
  spec: expenseItemReportSpec,
  source: CallbackReportSource(
    sourceId: 'expense_item',
    query: expenseItemReportRows,
    options: itemOptions,
  ),
);

class _ItemSpendAccum {
  _ItemSpendAccum({required this.itemLabel, required this.categoryLabel});

  String itemLabel;
  String categoryLabel;
  Decimal qty = Decimal.zero;
  Decimal purchase = Decimal.zero;
  Decimal expense = Decimal.zero;
  Decimal tax = Decimal.zero;

  Decimal get total => purchase + expense;
}

Future<List<ReportRow>> expenseItemReportRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selectedItem = selectedItemId(filters);

  // 1. Purchase bill lines (bills and debit notes) in the window.
  final pLines = db.purchaseBillItems;
  final bills = db.purchaseBills;
  final pQuery =
      db.select(pLines).join([
        innerJoin(bills, bills.id.equalsExp(pLines.billId)),
      ])..where(
        livePurchasesIn(window, firmId, bills) &
            pLines.isDeleted.equals(false) &
            (selectedItem == null
                ? const Constant(true)
                : pLines.itemId.equals(selectedItem)),
      );

  final pRows = await pQuery.get();

  // 2. Live expenses in the window.
  final eQuery = db.select(db.expenses)
    ..where(
      (e) =>
          liveExpensesIn(window, firmId, e) &
          (selectedItem == null
              ? const Constant(true)
              : e.itemId.equals(selectedItem)),
    );
  final eRows = await eQuery.get();

  if (pRows.isEmpty && eRows.isEmpty) return const [];

  // Collect all referenced itemIds to resolve current item names and categories.
  final itemIds = <String>{
    for (final r in pRows)
      if (r.readTable(pLines).itemId != null) r.readTable(pLines).itemId!,
    for (final e in eRows)
      if (e.itemId != null && e.itemId!.trim().isNotEmpty) e.itemId!.trim(),
  };

  final itemsMap = await itemsById(db, firmId, itemIds.toList());
  final itemCategories = await itemCategoryNames(db, firmId, itemsMap);

  final buckets = <String, _ItemSpendAccum>{};

  for (final joined in pRows) {
    final line = joined.readTable(pLines);
    final bill = joined.readTable(bills);
    final sign = Decimal.fromInt(signFor(bill.docType));
    final id = line.itemId?.trim();
    final hasId = id != null && id.isNotEmpty;
    final key = hasId ? 'item:$id' : 'line:${line.name.trim().toLowerCase()}';
    final itemName = hasId
        ? (itemsMap[id]?.name ?? line.name)
        : (line.name.trim().isEmpty ? 'Unnamed item' : line.name.trim());
    final catName = hasId ? (itemCategories[id] ?? 'Ungrouped') : 'Ungrouped';

    final acc = buckets.putIfAbsent(
      key,
      () => _ItemSpendAccum(itemLabel: itemName, categoryLabel: catName),
    );
    acc.qty += sign * dec(line.quantity);
    acc.purchase += sign * dec(line.taxableValue);
    acc.tax +=
        sign *
        outputTaxOf(
          cgst: line.cgst,
          sgst: line.sgst,
          igst: line.igst,
          cess: line.cessAmount,
        );
  }

  for (final exp in eRows) {
    final id = exp.itemId?.trim();
    final hasId = id != null && id.isNotEmpty;
    final expCat = expenseCategoryLabel(exp.category);
    final key = hasId ? 'item:$id' : 'cat:$expCat';
    final itemName = hasId ? (itemsMap[id]?.name ?? expCat) : expCat;
    final catName = hasId ? (itemCategories[id] ?? expCat) : expCat;

    final acc = buckets.putIfAbsent(
      key,
      () => _ItemSpendAccum(itemLabel: itemName, categoryLabel: catName),
    );
    final total = dec(exp.amount);
    final gst = dec(exp.gstAmount);
    final net = exp.itcEligible && gst > Decimal.zero && gst <= total
        ? total - gst
        : total;
    acc.expense += net;
    acc.tax += gst;
  }

  final rows = <ReportRow>[];
  for (final acc in buckets.values) {
    if (acc.qty == Decimal.zero &&
        acc.purchase == Decimal.zero &&
        acc.expense == Decimal.zero &&
        acc.tax == Decimal.zero) {
      continue;
    }
    rows.add(
      ReportRow({
        'item': acc.itemLabel,
        'category': acc.categoryLabel,
        'qty': acc.qty,
        'purchase': acc.purchase,
        'expense': acc.expense,
        'tax': acc.tax,
        'total': acc.total,
      }, label: acc.itemLabel),
    );
  }
  return rows;
}
