import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/engine/gst_engine.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/utils/money.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

// `item_common.dart` also exports a `dec`; the transaction one is imported
// without a prefix everywhere else in this layer, so it is the one kept.
import '../item_stock/item_common.dart' hide dec;
import '../transaction/transaction_common.dart';

/// **Discount Report** — what was given away, and where.
///
/// Two questions in one report: how much discount did we give in total, and
/// which item earned it. A shop owner wants the first as a percentage of
/// turnover and the second per product, because an item discounted hard every
/// month is a pricing decision rather than a sale.
///
/// **The per-line share of the invoice allowance is recovered from the books,
/// not apportioned a second time** — the same rule, and the same reason, as
/// `item_stock/item_wise_discount.dart`. `GstEngine` apportioned the header
/// allowance across the lines by largest remainder when the document was saved
/// and folded the result into the line's stored `taxableValue`. So the share
/// that was *actually applied* is `base.taxable − taxableValue`, and reading it
/// back cannot drift. Dividing the header again here would mean a second
/// apportionment that has to agree with the first to the paisa — and the bills
/// that divide badly are precisely the ones that come out wrong.
///
/// **Before discount is `rate × quantity`**, so `gross − discount == net` holds
/// on every row the reader is invited to check. Measuring the percentage
/// against the post-discount total would make it a function of the discount it
/// is reporting.
///
/// **A credit note takes the discount back off.** A returned sale was
/// discounted *less* over the period, not more.
const ReportSpec discountReportSpec = ReportSpec(
  id: 'discount_report',
  title: 'Discount Report',
  category: 'Business Status',
  sort: ReportSort(columnKey: 'discount', descending: true),
  columns: [
    ReportColumn(key: 'item', label: 'Item', flex: 3, emphasise: true),
    ReportColumn(
      key: 'gross',
      label: 'Before discount',
      kind: ReportValueKind.money,
      flex: 2,
    ),
    ReportColumn(
      key: 'discount',
      label: 'Discount given',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
    ReportColumn(
      key: 'percent',
      label: 'Discount %',
      kind: ReportValueKind.percent,
      colorize: true,
    ),
    ReportColumn(
      key: 'lineDiscount',
      label: 'Line discounts',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'invoiceDiscount',
      label: 'Invoice allowances',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'net',
      label: 'Net received',
      kind: ReportValueKind.money,
      flex: 2,
    ),
  ],
  footnote:
      'Discount given is the line discount plus that line\'s share of the '
      'invoice allowance the tax engine actually applied — read back from the '
      'books, not divided out again, so this reconciles with the return '
      'exactly. Before discount is rate x quantity with no allowance applied, '
      'so before discount less discount given equals net received on every row. '
      'A credit note reduces both, because a returned sale was discounted less, '
      'not more. Cancelled documents are excluded.',
);

const ReportDefinition discountReport = ReportDefinition(
  spec: discountReportSpec,
  source: CallbackReportSource(
    sourceId: 'discount_report',
    query: discountReportRows,
    options: itemOptions,
    notes: _discountReportNotes,
  ),
);

/// One item's discount across the period.
class _DiscountFor {
  var gross = Decimal.zero;
  var discount = Decimal.zero;
  var lineDiscount = Decimal.zero;
  var invoiceDiscount = Decimal.zero;
  var net = Decimal.zero;

  /// The discount as a percentage of the value before discount, to two places.
  ///
  /// **Converts at scale 6, then rounds once** — the rule the margin percentage
  /// already depends on. A bare `toDecimal()` *throws* on a non-terminating
  /// fraction, so a one-third discount would take the whole report down, and
  /// converting straight to two places truncates: two thirds reads 66.66 where
  /// `Money.round2` gives 66.67.
  Decimal get percent => gross == Decimal.zero
      ? Decimal.zero
      : Money.round2(
          (discount * Decimal.fromInt(100) / gross).toDecimal(
            scaleOnInfinitePrecision: 6,
          ),
        );
}

Future<List<ReportRow>> discountReportRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = selectedItemId(filters);

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
                l.isDeleted.equals(false) &
                // `itemScope` is the one spelling of "this item, or all of them"
                // the Item/Stock reports use; a hand-rolled null branch here is how
                // a filter silently stops matching.
                itemScope(l.itemId, selected),
          ))
          .get();

  // The sign is the document's, so a credit note comes off its own item.
  final signs = <String, int>{
    for (final doc in docs) doc.id: signFor(doc.docType),
  };

  final byItem = <String, _DiscountFor>{};
  final names = <String, String>{};
  for (final line in lines) {
    final sign = Decimal.fromInt(signs[line.invoiceId] ?? 1);
    final gross = dec(line.rate) * dec(line.quantity);
    final taxable = dec(line.taxableValue);

    // The line's taxable value before the *document* allowance — which is what
    // the engine apportioned across, and therefore what the share is a share
    // of. Delegated to the engine rather than re-derived: a line discount can be
    // a percentage, an amount, or both, clamped to the line's own value, and
    // `taxable` is the same under all three splits — the split only decides which
    // tax head an amount lands in.
    // One call to the engine for both figures, so the discount this report prints
    // is the discount the tax was computed on. Reading `discountAmount` off the
    // line instead would miss a percentage discount entirely — the column holds
    // only the *amount* half, and `discountPercent` is a separate one. A 10%
    // discount typed as a percentage reports zero here while the invoice shows
    // ₹500 off, which is the kind of disagreement that makes a shopkeeper stop
    // trusting the report.
    final engine = GstEngine.computeLine(
      TaxLine(
        id: '',
        name: line.name,
        quantity: dec(line.quantity),
        unit: line.unit,
        rate: dec(line.rate),
        discountPercent: dec(line.discountPercent),
        discountAmount: line.discountAmount == 0
            ? null
            : dec(line.discountAmount),
        gstRate: line.gstRate,
        cessRate: line.cessRate,
        taxMode: line.taxMode == 'inclusive'
            ? TaxMode.inclusive
            : TaxMode.exclusive,
      ),
      GstSplit.intraState,
    );
    final baseTaxable = engine.taxable;
    // The line's own discount, percentage and amount both, clamped to the line
    // by the engine rather than by this report.
    final lineDiscount = engine.discount;

    // The share, exactly as the engine applied it. Signed like everything else,
    // so a credit note's return carries a negative and nets against the sale it
    // cancels.
    final share = baseTaxable - taxable;

    // Keyed on the item, or on the typed name when the line has no item — a
    // hand-keyed line belongs in the report under whatever the user called it
    // rather than vanishing because it could not be joined.
    final key = line.itemId ?? 'name:${line.name}';
    names[key] = line.name;
    final entry = byItem.putIfAbsent(key, _DiscountFor.new);
    entry.gross += sign * gross;
    entry.lineDiscount += sign * lineDiscount;
    entry.invoiceDiscount += sign * share;
    entry.discount += sign * (lineDiscount + share);
    entry.net += sign * (gross - lineDiscount - share);
  }

  return [
    for (final entry in byItem.entries)
      ReportRow({
        'item': names[entry.key] ?? entry.key,
        'gross': entry.value.gross,
        'discount': entry.value.discount,
        'percent': entry.value.percent,
        'lineDiscount': entry.value.lineDiscount,
        'invoiceDiscount': entry.value.invoiceDiscount,
        'net': entry.value.net,
      }, label: names[entry.key] ?? entry.key),
  ];
}

/// A function, not a string — the source's `notes` slot is
/// `List<String> Function(ReportResult)`.
List<String> _discountReportNotes(ReportResult result) => [
  'Reads sales invoice lines in the window. A line with no item still '
      'appears, under the name the user typed.',
];
