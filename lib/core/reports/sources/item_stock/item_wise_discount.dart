import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/engine/gst_engine.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import 'item_common.dart';
import '../transaction/transaction_common.dart' show signFor;

/// **Item Wise Discount** — where the allowance went, and what it cost.
///
/// Two kinds of discount exist and they are stored in different places, so this
/// report shows both rather than merging them into one figure that is really
/// two figures added together:
///
///  * a **line discount** on `sales_invoice_items.discountAmount`, entered per
///    line, and
///  * an **invoice discount** on `sales_invoices.invoiceDiscountAmount`,
///    entered once on the document.
///
/// **The invoice discount's per-item share is recovered from the stored taxable
/// value, not apportioned again.** `GstEngine._apportionInvoiceDiscount`
/// (`gst_engine.dart:556`) apportions it across the lines when the document is
/// saved, and the share it computed is written into `taxableValue` — the share
/// itself is not kept. So reading only the header gives a document-level total
/// with no way to attribute it to an item, and reading only the lines omits it
/// entirely. But since `taxableValue = round2(lineBase − share)`, the share is
/// `lineBase − taxableValue`, and this report reports the figure the tax was
/// actually computed on rather than a second apportionment that would have to
/// agree with the engine's to the paisa. See `_rows`.
///
/// **A credit note's discount is stored positive**, like its other figures, so
/// the sign is applied in Dart from `docType` — the same trap `party_common.dart`
/// and `tradingByItem` both carry, and the reason the query groups by `docType`
/// as well as item.
const ReportSpec itemWiseDiscountSpec = ReportSpec(
  id: 'item_wise_discount',
  title: 'Item Wise Discount',
  category: 'Item/Stock',
  sort: ReportSort(columnKey: 'discount', descending: true),
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
    ReportColumn(key: 'category', label: 'Category'),
    ReportColumn(key: 'side', label: 'Side'),
    ReportColumn(
      key: 'gross',
      label: 'Before discount',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'lineDiscount',
      label: 'Line discount',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'invoiceDiscount',
      label: 'Invoice discount',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'discount',
      label: 'Total discount',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
    ReportColumn(
      key: 'net',
      label: 'After discount',
      kind: ReportValueKind.money,
      emphasise: true,
    ),
    ReportColumn(
      key: 'percent',
      label: 'Discount %',
      kind: ReportValueKind.percent,
    ),
  ],
  footnote:
      'Before discount is the line\'s value with no allowance applied. '
      'Invoice discount is the document-level allowance, and each line\'s share '
      'of it is the one the tax engine actually applied — read back from the '
      'line\'s stored taxable value rather than divided out again, so this '
      'reconciles with the return exactly. Credit notes are netted.',
);

const ReportDefinition itemWiseDiscount = ReportDefinition(
  spec: itemWiseDiscountSpec,
  source: CallbackReportSource(
    sourceId: 'item_wise_discount',
    query: itemWiseDiscountRows,
    options: itemOptions,
  ),
);

Future<List<ReportRow>> itemWiseDiscountRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedItemId(filters);
  final sales = await _discounts(db, firmId, window, selected, sale: true);
  final purchases = await _discounts(db, firmId, window, selected, sale: false);
  final rows = [...sales, ...purchases];
  if (rows.isEmpty) return rows;

  final ids = rows.map((r) => r.cells['itemId'] as String).toSet().toList();
  final items = await itemsById(db, firmId, ids);
  final categories = await itemCategoryNames(db, firmId, items);

  return [
    for (final row in rows)
      ReportRow({
        ...row.cells,
        'item': items[row.cells['itemId']]?.name ?? '(deleted item)',
        'category': categories[row.cells['itemId']] ?? 'Ungrouped',
      }),
  ];
}

/// One side of the report: sales lines or purchase lines.
///
/// **Read per document, not per item.** The invoice discount lives on the
/// header and has to be spread across that document's lines before it can be
/// attributed to any of them, so the grouping key is the document — and the
/// per-item accumulation happens afterwards, in Dart. Grouping by item in SQL
/// would lose the header figure entirely, since nothing on the line records its
/// share of it.
Future<List<ReportRow>> _discounts(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  String? selected, {
  required bool sale,
}) async {
  if (sale) {
    final lines = db.salesInvoiceItems;
    final invoices = db.salesInvoices;
    final query = db.selectOnly(lines)
      ..join([innerJoin(invoices, invoices.id.equalsExp(lines.invoiceId))])
      // **The header's allowance is deliberately not selected.** The share is
      // recovered from `taxableValue` rather than divided out of it, so reading
      // the header column here would only invite the mistake of summing it once
      // per line.
      //
      // The line's own inputs *are* selected, because `base.taxable` has to be
      // reproduced from them — see `_rows`.
      ..addColumns([
        lines.itemId,
        invoices.docType,
        lines.taxableValue,
        lines.quantity,
        lines.rate,
        lines.discountPercent,
        lines.discountAmount,
        lines.gstRate,
        lines.cessRate,
        lines.taxMode,
        lines.name,
      ])
      ..where(
        invoices.firmId.equals(firmId) &
            invoices.docType.isIn(const ['invoice', 'credit_note']) &
            ReportFilters.isLive(
              status: invoices.status,
              isDeleted: invoices.isDeleted,
            ) &
            ReportFilters.within(invoices.invoiceDate, window) &
            itemScope(lines.itemId, selected),
      )
    // **Not grouped, and not ordered.** Each line's own figures are needed
    // separately, so every line is fetched and accumulated in Dart. The order
    // is irrelevant because `_rows` accumulates rather than emitting as it
    // reads.
    ;
    final results = await query.get();

    return _rows(
      results,
      sale: true,
      itemOf: (row) => row.read(lines.itemId),
      docTypeOf: (row) => '${row.read(invoices.docType)}',
      taxableOf: (row) => dec(row.read(lines.taxableValue) ?? 0),
      grossOf: (row) =>
          dec(row.read(lines.quantity) ?? 0) * dec(row.read(lines.rate) ?? 0),
      lineDiscountOf: (row) => dec(row.read(lines.discountAmount) ?? 0),
      lineBaseTaxable: (row) => _baseTaxable(
        quantity: dec(row.read(lines.quantity) ?? 0),
        rate: dec(row.read(lines.rate) ?? 0),
        discountPercent: dec(row.read(lines.discountPercent) ?? 0),
        discountAmount: dec(row.read(lines.discountAmount) ?? 0),
        gstRate: dec(row.read(lines.gstRate) ?? 0),
        cessRate: dec(row.read(lines.cessRate) ?? 0),
        taxMode: '${row.read(lines.taxMode)}',
        name: '${row.read(lines.name)}',
      ),
    );
  }

  final lines = db.purchaseBillItems;
  final bills = db.purchaseBills;
  final query = db.selectOnly(lines)
    ..join([innerJoin(bills, bills.id.equalsExp(lines.billId))])
    ..addColumns([
      lines.itemId,
      bills.docType,
      lines.taxableValue,
      lines.quantity,
      lines.rate,
      lines.discountPercent,
      lines.discountAmount,
      lines.gstRate,
      lines.cessRate,
      lines.taxMode,
      lines.name,
    ])
    ..where(
      bills.firmId.equals(firmId) &
          bills.docType.isIn(const ['bill', 'debit_note']) &
          ReportFilters.isLive(
            status: bills.status,
            isDeleted: bills.isDeleted,
          ) &
          ReportFilters.within(bills.billDate, window) &
          itemScope(lines.itemId, selected),
    );

  return _rows(
    await query.get(),
    sale: false,
    itemOf: (row) => row.read(lines.itemId),
    docTypeOf: (row) => '${row.read(bills.docType)}',
    taxableOf: (row) => dec(row.read(lines.taxableValue) ?? 0),
    grossOf: (row) =>
        dec(row.read(lines.quantity) ?? 0) * dec(row.read(lines.rate) ?? 0),
    lineDiscountOf: (row) => dec(row.read(lines.discountAmount) ?? 0),
    lineBaseTaxable: (row) => _baseTaxable(
      quantity: dec(row.read(lines.quantity) ?? 0),
      rate: dec(row.read(lines.rate) ?? 0),
      discountPercent: dec(row.read(lines.discountPercent) ?? 0),
      discountAmount: dec(row.read(lines.discountAmount) ?? 0),
      gstRate: dec(row.read(lines.gstRate) ?? 0),
      cessRate: dec(row.read(lines.cessRate) ?? 0),
      taxMode: '${row.read(lines.taxMode)}',
      name: '${row.read(lines.name)}',
    ),
  );
}

/// A line's taxable value **before** the document allowance — the figure
/// `GstEngine` apportions the header discount across.
///
/// **Delegated, not re-implemented.** `computeLine` already implements the whole
/// rule — percentage plus amount, clamped to the line's own value, and
/// back-calculated when the line's tax is inclusive — and a second copy here
/// would be free to drift from it. The `GstSplit` argument is not load-bearing:
/// it only decides which head a tax amount lands in, and `taxable` is the same
/// under all three.
///
/// `name` is carried because `TaxLine` requires it; it is not read.
Decimal _baseTaxable({
  required Decimal quantity,
  required Decimal rate,
  required Decimal discountPercent,
  required Decimal discountAmount,
  required Decimal gstRate,
  required Decimal cessRate,
  required String taxMode,
  required String name,
}) => GstEngine.computeLine(
  TaxLine(
    id: '',
    name: name,
    quantity: quantity,
    unit: '',
    rate: rate,
    discountPercent: discountPercent,
    discountAmount: discountAmount,
    gstRate: gstRate.toDouble(),
    cessRate: cessRate.toDouble(),
    taxMode: taxMode == 'inclusive' ? TaxMode.inclusive : TaxMode.exclusive,
  ),
  GstSplit.intraState,
).taxable;

/// Signs, reads each line's share of the header discount, and accumulates per
/// item.
///
/// **The share is read from the books, not recomputed.** `GstEngine` already
/// apportioned the header allowance across the lines when the document was
/// saved, by largest remainder, and folded the result into the line's stored
/// `taxableValue` (`gst_engine.dart:462-463`: `taxableValue = round2(base
/// .taxable - lineInvoiceDiscounts[i])`). So the share that was actually applied
/// is `base.taxable − taxableValue`, and subtracting it recovers the figure the
/// tax was computed on.
///
/// **That is better than dividing, and not only because it is easier.** Dividing
/// the header allowance here means a second apportionment that has to agree with
/// the first one — and a report that disagreed with the tax return by a paisa
/// would be a support call. A ₹10 allowance across three equal lines is 3.33,
/// 3.33, 3.34 under largest remainder; any straight division produces a
/// different set, and it is precisely the bills that divide badly — three of the
/// same thing, the commonest bill there is — that come out wrong.
///
/// **`base.taxable` comes from `GstEngine.computeLine`, not from a second copy of
/// its arithmetic.** A line discount can be a percentage, an amount, or both, and
/// `_lineDiscount` clamps the pair to the line's own value; re-deriving that here
/// would be a third implementation of a rule that already has two. Calling the
/// engine also gets the **inclusive**-tax case right for free, where
/// `base.taxable` is a back-calculated figure and not `gross − discount` at all.
/// The `GstSplit` is irrelevant to `taxable` — it only decides which tax head the
/// amount lands in — so the split argument is not load-bearing here.
///
/// **No `Decimal.one`, no rounding, no `toDecimal`.** Every figure here is a
/// stored value read back and added, so the columns reconcile exactly.
List<ReportRow> _rows(
  List<TypedResult> results, {
  required bool sale,
  required String? Function(TypedResult) itemOf,
  required String Function(TypedResult) docTypeOf,
  required Decimal Function(TypedResult) taxableOf,
  required Decimal Function(TypedResult) grossOf,
  required Decimal Function(TypedResult) lineDiscountOf,
  required Decimal Function(TypedResult) lineBaseTaxable,
}) {
  final side = sale ? 'Sale' : 'Purchase';
  final byItem = <String, _DiscountRow>{};
  for (final row in results) {
    final id = itemOf(row);
    if (id == null) continue;
    // `Decimal.one` is declared without a type annotation in the decimal package
    // (`static final one = Decimal.fromInt(1)`), so it infers as `Object` and
    // poisons every expression it reaches. `Decimal.fromInt(1)` is typed, and
    // the cast-free spelling is worth the verbosity.
    final Decimal sign = Decimal.fromInt(signFor(docTypeOf(row)));
    final taxable = taxableOf(row);
    final gross = grossOf(row);
    final Decimal lineDiscount = sign * lineDiscountOf(row);
    // The line's taxable value before the **document** allowance — which is what
    // the engine apportioned across, and therefore what the share is a share *of*.
    final Decimal baseTaxable = sign * lineBaseTaxable(row);
    // The share, exactly as applied. Signed like everything else, so a credit
    // note's return carries a negative and nets against the sale it cancels.
    final Decimal share = baseTaxable - taxable;
    final entry = byItem[id] ??= _DiscountRow(side);
    entry
      // Gross is the value before **either** discount, so `gross − discount`
      // lands exactly on `net` and the reader can check it on any row.
      ..gross += sign * gross
      ..lineDiscount += lineDiscount
      ..invoiceDiscount += share
      ..net += taxable;
  }

  return [
    for (final entry in byItem.entries)
      ReportRow({
        'itemId': entry.key,
        'item': entry.key,
        'side': entry.value.side,
        'gross': entry.value.gross,
        'lineDiscount': entry.value.lineDiscount,
        'invoiceDiscount': entry.value.invoiceDiscount,
        'discount': entry.value.lineDiscount + entry.value.invoiceDiscount,
        'net': entry.value.net,
        'percent': entry.value.gross == Decimal.zero
            ? Decimal.zero
            // `marginPercent` rather than the same expression spelled again: this is the
            // same ratio as a margin — a discount as a percentage of gross — and
            // two spellings of a percentage is how two reports of the same month
            // come to disagree by a hundredth. It handles the ÷3 case and the
            // HALF_UP rounding that the share above also needs.
            : marginPercent(
                entry.value.lineDiscount + entry.value.invoiceDiscount,
                entry.value.gross,
              ),
        // `net` is stored, not derived, so `gross − discount` and `net` agree
        // exactly on every row rather than only on the total.
      }, label: entry.key),
  ];
}

/// Accumulator for one item's discount figures.
class _DiscountRow {
  _DiscountRow(this.side);

  final String side;
  Decimal gross = Decimal.zero;
  Decimal lineDiscount = Decimal.zero;
  Decimal invoiceDiscount = Decimal.zero;
  Decimal net = Decimal.zero;
}
