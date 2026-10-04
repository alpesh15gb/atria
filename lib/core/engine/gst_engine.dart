import 'package:decimal/decimal.dart';

import '../constants/indian_states.dart';
import '../utils/money.dart';

/// How tax is applied to a line item.
enum TaxMode {
  /// Tax added on top of the taxable value (default).
  exclusive,

  /// Tax already included in the item price.
  inclusive,
}

/// Which GST split applies to a transaction.
enum GstSplit {
  /// Same state: CGST + SGST.
  intraState,

  /// Different states: IGST.
  interState,

  /// Supplier/buyer in a UT: CGST + UTGST.
  ut,
}

/// What the second half of an intra-state tax split is called on a document.
///
/// The arithmetic is identical either way, but a dealer in or supplying a Union
/// Territory charges CGST + **UTGST**, and a tax invoice that says SGST is a
/// misstatement on the face of the document the customer reconciles against
/// their own return. Cosmetic on a screen, not on paper.
String intraStateSecondHead(GstSplit split) =>
    split == GstSplit.ut ? 'UTGST' : 'SGST';

/// Determines the GST split from the two state codes involved.
GstSplit resolveGstSplit({String? supplierState, String? buyerState}) {
  if (supplierState == null || buyerState == null) {
    return GstSplit.intraState;
  }
  if (supplierState != buyerState) {
    return GstSplit.interState;
  }
  // Same state code: UTGST states use CGST + UTGST instead of SGST.
  if (IndianStates.utgstStates.contains(supplierState)) {
    return GstSplit.ut;
  }
  return GstSplit.intraState;
}

/// One line of a taxable document (shared by invoices, quotations, purchases).
class TaxLine {
  final String id;
  final String? itemId;
  final String name;
  final String? hsn;
  final Decimal quantity;
  final String unit;
  final Decimal rate;
  final Decimal? discountPercent;
  final Decimal? discountAmount;
  final double gstRate; // 0, 0.25, 3, 5, 12, 18, 28
  final double cessRate; // % over and above GST
  final TaxMode taxMode;

  TaxLine({
    required this.id,
    this.itemId,
    required this.name,
    this.hsn,
    required this.quantity,
    required this.unit,
    required this.rate,
    this.discountPercent,
    this.discountAmount,
    required this.gstRate,
    this.cessRate = 0,
    this.taxMode = TaxMode.exclusive,
  });

  factory TaxLine.empty() => TaxLine(
        id: '',
        name: '',
        quantity: Money.zero,
        unit: 'pcs',
        rate: Money.zero,
        gstRate: 0,
      );

  TaxLine copyWith({
    String? id,
    String? itemId,
    String? name,
    String? hsn,
    Decimal? quantity,
    String? unit,
    Decimal? rate,
    Decimal? discountPercent,
    Decimal? discountAmount,
    double? gstRate,
    double? cessRate,
    TaxMode? taxMode,
  }) {
    return TaxLine(
      id: id ?? this.id,
      itemId: itemId ?? this.itemId,
      name: name ?? this.name,
      hsn: hsn ?? this.hsn,
      quantity: quantity ?? this.quantity,
      unit: unit ?? this.unit,
      rate: rate ?? this.rate,
      discountPercent: discountPercent ?? this.discountPercent,
      discountAmount: discountAmount ?? this.discountAmount,
      gstRate: gstRate ?? this.gstRate,
      cessRate: cessRate ?? this.cessRate,
      taxMode: taxMode ?? this.taxMode,
    );
  }
}

/// Per-line computed values.
class LineTotals {
  final Decimal gross; // qty * rate
  final Decimal discount; // line discount only
  final Decimal taxable; // after line discount (before invoice-level discount)
  final Decimal cgst;
  final Decimal sgst;
  final Decimal igst;
  final Decimal cess;
  final Decimal total; // taxable + taxes
  final Decimal taxExclusiveBase; // for inclusive mode: value without tax

  LineTotals({
    required this.gross,
    required this.discount,
    required this.taxable,
    required this.cgst,
    required this.sgst,
    required this.igst,
    required this.cess,
    required this.total,
    required this.taxExclusiveBase,
  });

  Decimal get tax => cgst + sgst + igst + cess;

  factory LineTotals.empty() => LineTotals(
        gross: Money.zero,
        discount: Money.zero,
        taxable: Money.zero,
        cgst: Money.zero,
        sgst: Money.zero,
        igst: Money.zero,
        cess: Money.zero,
        total: Money.zero,
        taxExclusiveBase: Money.zero,
      );
}

/// GST rate-wise aggregation (the shape needed for GSTR-style reports).
class RateWiseTax {
  final double rate;
  final Decimal taxableValue;
  final Decimal cgst;
  final Decimal sgst;
  final Decimal igst;
  final Decimal cess;
  final int lineCount;

  RateWiseTax({
    required this.rate,
    required this.taxableValue,
    required this.cgst,
    required this.sgst,
    required this.igst,
    required this.cess,
    required this.lineCount,
  });
}

/// Per-line result of [GstEngine.computeDocument], for the line tables. The
/// tax columns on `sales_invoice_items` / `purchase_bill_items` are what the
/// detail screen's line table and the PDF's item grid render, so the resolved
/// values have to be persisted rather than recomputed at read time.
class ComputedLine {
  final String lineId;
  final Decimal taxableValue;
  final Decimal cgst;
  final Decimal sgst;
  final Decimal igst;
  final Decimal cess;
  final Decimal total;

  ComputedLine({
    required this.lineId,
    required this.taxableValue,
    required this.cgst,
    required this.sgst,
    required this.igst,
    required this.cess,
    required this.total,
  });
}

/// Complete result of a document tax calculation.
class GstResult {
  final Decimal subTotal; // sum of line gross values
  final Decimal itemDiscountTotal;
  final Decimal invoiceDiscount; // invoice-level discount applied
  final Decimal taxableValue; // final taxable base
  final Decimal cgstTotal;
  final Decimal sgstTotal;
  final Decimal igstTotal;
  final Decimal cessTotal;
  final Decimal roundOff;
  final Decimal grandTotal;
  final GstSplit split;
  final List<RateWiseTax> rateWise;
  final List<ComputedLine> lines;

  GstResult({
    required this.subTotal,
    required this.itemDiscountTotal,
    required this.invoiceDiscount,
    required this.taxableValue,
    required this.cgstTotal,
    required this.sgstTotal,
    required this.igstTotal,
    required this.cessTotal,
    required this.roundOff,
    required this.grandTotal,
    required this.split,
    required this.rateWise,
    this.lines = const [],
  });

  Decimal get totalTax => cgstTotal + sgstTotal + igstTotal + cessTotal;

  /// The computed values for [lineId], or `null` when the id wasn't in the
  /// input list (a caller building a draft piecemeal, for instance).
  ComputedLine? lineFor(String lineId) {
    for (final l in lines) {
      if (l.lineId == lineId) return l;
    }
    return null;
  }

  factory GstResult.empty() => GstResult(
        subTotal: Money.zero,
        itemDiscountTotal: Money.zero,
        invoiceDiscount: Money.zero,
        taxableValue: Money.zero,
        cgstTotal: Money.zero,
        sgstTotal: Money.zero,
        igstTotal: Money.zero,
        cessTotal: Money.zero,
        roundOff: Money.zero,
        grandTotal: Money.zero,
        split: GstSplit.intraState,
        rateWise: const [],
      );
}

/// The GST engine. Pure functions, no side effects — easy to unit test.
class GstEngine {
  GstEngine._();

  /// The invoice-level discount a *stored* document actually received.
  ///
  /// Only the discount's inputs are persisted (`invoiceDiscountPercent` and
  /// `invoiceDiscountAmount`); the engine resolves, clamps and apportions the
  /// real figure at save time, and the amount column stays 0 for a percent
  /// discount. Readers that need the number — the PDF totals block and the
  /// detail card — recover it from the invariant
  /// `taxableValue == subTotal - itemDiscount - invoiceDiscount`. With no
  /// discount the apportionment ratio is 0, so every line rounds to itself and
  /// the result is exactly 0 rather than rounding noise.
  /// The invoice-level discount actually applied, from the stored columns.
  ///
  /// The old inference `subTotal − itemDiscount − taxableValue` is only
  /// correct for tax-EXCLUSIVE lines: on tax-inclusive lines the difference
  /// also contains the tax itself, so a no-discount invoice printed a
  /// phantom "Discount" row equal to the tax. The stored percent/amount
  /// columns are exact in both modes: percent is applied on
  /// (subTotal − itemDiscount) by the engine before tax extraction, so that
  /// product reproduces it; amount is what the user entered.
  static double resolvedInvoiceDiscount({
    required double subTotal,
    required double itemDiscount,
    required double invoiceDiscountPercent,
    required double invoiceDiscountAmount,
  }) {
    if (invoiceDiscountPercent > 0.0001) {
      return (subTotal - itemDiscount) * invoiceDiscountPercent / 100.0;
    }
    return invoiceDiscountAmount < 0 ? 0 : invoiceDiscountAmount;
  }

  /// Tax deducted (TDS) or collected (TCS) at source on a document.
  ///
  /// Worked out on the *taxable value*, which is the reading both sides of the
  /// transaction use: s.206C(1H)'s Explanation excludes GST from the sale
  /// consideration TCS is charged on, and a 194Q deduction is taken on the
  /// value of the goods rather than on the GST the buyer also paid. Applying it
  /// to the grand total would over-deduct by the tax on every document.
  ///
  /// Zero for a null or non-positive rate, so a caller that has no TDS/TCS
  /// field wired up yet gets exactly the behaviour it had before.
  static Decimal settlementTax({
    required Decimal taxableValue,
    Decimal? rate,
  }) {
    if (rate == null || rate <= Money.zero) return Money.zero;
    return Money.percent(taxableValue, rate.toDouble());
  }

  /// Computes a single line, ignoring invoice-level discounts (which are
  /// applied proportionally by [computeDocument]).
  static LineTotals computeLine(TaxLine line, GstSplit split) {
    final gross = line.quantity * line.rate;
    final lineDiscount = _lineDiscount(line, gross);
    final afterLineDiscount = gross - lineDiscount;

    Decimal taxable = afterLineDiscount;
    Decimal taxExclusiveBase = afterLineDiscount;
    Decimal cgst = Money.zero;
    Decimal sgst = Money.zero;
    Decimal igst = Money.zero;
    Decimal cess = Money.zero;

    if (line.taxMode == TaxMode.inclusive) {
      // Back-calculate the taxable value: taxable = total / (1 + rate/100).
      final divisor = Decimal.parse((1 + line.gstRate / 100).toString());
      taxable = Money.div(afterLineDiscount, divisor);
      taxExclusiveBase = taxable;
      final taxAmount = afterLineDiscount - taxable;
      _splitTax(taxAmount, split, (c, s, i) {
        cgst = c;
        sgst = s;
        igst = i;
      });
      cess = Money.percent(taxable, line.cessRate);
    } else {
      final taxAmount = Money.percent(taxable, line.gstRate);
      _splitTax(taxAmount, split, (c, s, i) {
        cgst = c;
        sgst = s;
        igst = i;
      });
      cess = Money.percent(taxable, line.cessRate);
    }

    final total = taxable + cgst + sgst + igst + cess;

    return LineTotals(
      gross: gross,
      discount: lineDiscount,
      taxable: taxable,
      cgst: cgst,
      sgst: sgst,
      igst: igst,
      cess: cess,
      total: total,
      taxExclusiveBase: taxExclusiveBase,
    );
  }

  static Decimal _lineDiscount(TaxLine line, Decimal gross) {
    final pct = line.discountPercent;
    var discount = pct == null ? Money.zero : Money.over100(gross * pct);
    discount += line.discountAmount ?? Money.zero;
    if (discount > gross) discount = gross;
    if (discount < Money.zero) discount = Money.zero;
    return discount;
  }

  static void _splitTax(
      Decimal amount, GstSplit split, void Function(Decimal, Decimal, Decimal) onSplit) {
    switch (split) {
      case GstSplit.intraState:
      case GstSplit.ut:
        final half = Money.div(amount, Decimal.fromInt(2));
        // Adjust so the two halves always sum exactly to [amount].
        final other = amount - half;
        onSplit(half, other, Money.zero);
        break;
      case GstSplit.interState:
        onSplit(Money.zero, Money.zero, amount);
        break;
    }
  }

  /// Computes an entire document: lines + optional invoice-level discount +
  /// optional round-off to the nearest rupee.
  static GstResult computeDocument({
    required List<TaxLine> lines,
    required GstSplit split,
    Decimal? invoiceDiscountPercent,
    Decimal? invoiceDiscountAmount,
    bool applyRoundOff = true,
  }) {
    final invoiceDiscountPercentValue = invoiceDiscountPercent ?? Money.zero;
    final invoiceDiscountAmountValue = invoiceDiscountAmount ?? Money.zero;
    if (lines.isEmpty) return GstResult.empty();

    var subTotal = Money.zero;
    var itemDiscountTotal = Money.zero;
    final lineResults = <MapEntry<TaxLine, LineTotals>>[];

    for (final line in lines) {
      final totals = computeLine(line, split);
      lineResults.add(MapEntry(line, totals));
      subTotal += totals.gross;
      itemDiscountTotal += totals.discount;
    }

    final preDiscountTaxable =
        subTotal - itemDiscountTotal;

    // Invoice-level discount (apportioned across lines by taxable share).
    Decimal invoiceDiscount;
    if (invoiceDiscountPercentValue > Money.zero) {
      invoiceDiscount =
          Money.over100(preDiscountTaxable * invoiceDiscountPercentValue);
    } else {
      invoiceDiscount = invoiceDiscountAmountValue;
    }
    if (invoiceDiscount > preDiscountTaxable) {
      invoiceDiscount = preDiscountTaxable;
    }
    if (invoiceDiscount < Money.zero) invoiceDiscount = Money.zero;
    // A percent discount rarely lands on a whole paisa (7.5% of ₹299.97 is
    // ₹22.49775), and the apportionment below moves whole paisa, so settle the
    // discount itself to paisa first. Everything that reads it — the PDF, the
    // detail screen, the round-off — then sees a real money amount, and the
    // line taxables can sum to it exactly.
    invoiceDiscount = Money.round2(invoiceDiscount);

    // Apportion the invoice discount across the lines in whole paisa, by
    // largest fractional remainder.
    //
    // The previous version scaled each line by a ratio
    // (invoiceDiscount / preDiscountTaxable) instead, and that quotient usually
    // does not terminate — Money.div rounds it to two places, so ₹10 off a ₹300
    // line used 0.03 rather than 1/30 and left the line a rupee too high, while
    // ₹1 off ₹300 rounded to 0.00 and was dropped entirely even though the
    // invoice still printed "Discount ₹1.00". Handing out actual paisa keeps
    // the sum exact whatever the ratio happens to be.
    final lineInvoiceDiscounts = _apportionInvoiceDiscount(
      discount: invoiceDiscount,
      lineTaxables: [for (final entry in lineResults) entry.value.taxable],
    );

    var taxableValue = Money.zero;
    var cgstTotal = Money.zero;
    var sgstTotal = Money.zero;
    var igstTotal = Money.zero;
    var cessTotal = Money.zero;
    final byRate = <double, RateWiseTax>{};
    final computed = <ComputedLine>[];

    for (var i = 0; i < lineResults.length; i++) {
      final line = lineResults[i].key;
      final base = lineResults[i].value;
      final lineTaxable =
          Money.round2(base.taxable - lineInvoiceDiscounts[i]);

      // Recompute tax on the apportioned taxable value.
      final taxAmount = Money.percent(lineTaxable, line.gstRate);
      Decimal cgst = Money.zero;
      Decimal sgst = Money.zero;
      Decimal igst = Money.zero;
      _splitTax(taxAmount, split, (c, s, interState) {
        cgst = c;
        sgst = s;
        igst = interState;
      });
      final cess = Money.percent(lineTaxable, line.cessRate);

      taxableValue += lineTaxable;
      cgstTotal += cgst;
      sgstTotal += sgst;
      igstTotal += igst;
      cessTotal += cess;

      final existing = byRate[line.gstRate];
      byRate[line.gstRate] = RateWiseTax(
        rate: line.gstRate,
        taxableValue:
            (existing?.taxableValue ?? Money.zero) + lineTaxable,
        cgst: (existing?.cgst ?? Money.zero) + cgst,
        sgst: (existing?.sgst ?? Money.zero) + sgst,
        igst: (existing?.igst ?? Money.zero) + igst,
        cess: (existing?.cess ?? Money.zero) + cess,
        lineCount: (existing?.lineCount ?? 0) + 1,
      );
      // `discountForLine` here is the *invoice* discount apportioned onto this
      // line, not an item discount — adding it to [itemDiscountTotal] would
      // fold the invoice discount into the item-discount column, and the PDF
      // and detail screen then print it twice (they add the two columns).
      computed.add(ComputedLine(
        lineId: line.id,
        taxableValue: lineTaxable,
        cgst: cgst,
        sgst: sgst,
        igst: igst,
        cess: cess,
        total: lineTaxable + cgst + sgst + igst + cess,
      ));
    }

    final unrounded = taxableValue + cgstTotal + sgstTotal + igstTotal + cessTotal;
    Decimal roundOff = Money.zero;
    if (applyRoundOff) {
      final rounded = unrounded.round(scale: 0);
      roundOff = rounded - unrounded;
    }

    final grandTotal = unrounded + roundOff;

    final rateWise = byRate.values.toList()
      ..sort((a, b) => a.rate.compareTo(b.rate));

    return GstResult(
      subTotal: subTotal,
      itemDiscountTotal: itemDiscountTotal,
      invoiceDiscount: invoiceDiscount,
      taxableValue: taxableValue,
      cgstTotal: cgstTotal,
      sgstTotal: sgstTotal,
      igstTotal: igstTotal,
      cessTotal: cessTotal,
      roundOff: roundOff,
      grandTotal: grandTotal,
      split: split,
      rateWise: rateWise,
      lines: computed,
    );
  }

  /// Splits [discount] across [lineTaxables] in proportion to each line's
  /// taxable value, working in whole paisa.
  ///
  /// The returned list has one entry per input line. Each entry is a multiple
  /// of ₹0.01, none is negative, none exceeds its own line's taxable value, and
  /// together they sum to exactly [discount] — so the apportionment neither
  /// invents nor loses money however awkward the ratio (₹10 across ₹300 is
  /// 1/30 per line, which has no finite decimal expansion).
  ///
  /// It does that with the standard largest-remainder rule: integer division
  /// gives every line a floor share and discards a fractional paisa, then the
  /// leftover paisa go back out one at a time to the lines that were furthest
  /// from their true share. As long as [discount] fits inside the total there is
  /// always room to place them, because a line's spare capacity is at least its
  /// own discarded fraction.
  static List<Decimal> _apportionInvoiceDiscount({
    required Decimal discount,
    required List<Decimal> lineTaxables,
  }) {
    if (discount <= Money.zero || lineTaxables.isEmpty) {
      return List<Decimal>.filled(lineTaxables.length, Money.zero);
    }

    Decimal fromPaisa(int paisa) {
      final rupees = paisa ~/ 100;
      final p = paisa % 100;
      return Decimal.parse('$rupees.${p.toString().padLeft(2, '0')}');
    }

    // Paisa are exact integers, so the division and the sort below never have
    // to round and never see floating-point error.
    int toPaisa(Decimal value) =>
        (value * Decimal.fromInt(100)).toBigInt().toInt();

    final caps = [for (final taxable in lineTaxables) toPaisa(taxable)];
    final totalPaisa = caps.fold<int>(0, (sum, cap) => sum + cap);
    if (totalPaisa <= 0) {
      return List<Decimal>.filled(lineTaxables.length, Money.zero);
    }

    // A sub-paisa taxable (a rate entered to three places, say) can make the
    // truncated total a paisa short of the discount; keep the discount inside
    // what is actually here rather than over-discount the last line.
    var discountPaisa = toPaisa(discount);
    if (discountPaisa > totalPaisa) discountPaisa = totalPaisa;
    if (discountPaisa < 0) discountPaisa = 0;

    final shares = [for (final cap in caps) discountPaisa * cap ~/ totalPaisa];
    var leftover =
        discountPaisa - shares.fold<int>(0, (sum, share) => sum + share);

    if (leftover > 0) {
      // Largest fractional remainder first, which keeps each line closest to
      // its true proportional share.
      final order = List<int>.generate(caps.length, (i) => i)
        ..sort(
          (a, b) => (discountPaisa * caps[b] % totalPaisa)
              .compareTo(discountPaisa * caps[a] % totalPaisa),
        );
      for (var j = 0; leftover > 0 && j < order.length; j++) {
        final i = order[j];
        if (shares[i] < caps[i]) {
          shares[i] += 1;
          leftover -= 1;
        }
      }
      // Leftover is zero for any paisa-clean input; the clamp above is what
      // makes that provable, so a paisa left here means a sub-paisa input was
      // truncated away rather than that a line was over-discounted.
      assert(leftover == 0);
    }

    return [for (final share in shares) fromPaisa(share)];
  }
}
