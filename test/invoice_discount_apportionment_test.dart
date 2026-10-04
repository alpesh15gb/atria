import 'package:atria/core/engine/gst_engine.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

/// The invoice-level-discount apportionment.
///
/// The engine used to scale every line by `invoiceDiscount / preDiscountTaxable`
/// and that quotient almost never terminates, so it was rounded to two places.
/// For a discount that does not divide evenly that moved real money: ₹10 off a
/// ₹300 bill is 1/30, which became 0.03 and left the line a rupee too high, and
/// ₹1 off ₹300 became 0.00 and was dropped while the invoice still printed
/// "Discount ₹1.00". The engine now moves whole paisa instead, so this file pins
/// the invariant that actually matters: the line taxables sum to exactly what
/// the invoice says was discounted.
void main() {
  TaxLine line({
    required String id,
    double qty = 1,
    required double rate,
    double gst = 0,
    TaxMode mode = TaxMode.exclusive,
  }) {
    return TaxLine(
      id: id,
      name: 'Test item',
      quantity: Decimal.parse(qty.toString()),
      unit: 'pcs',
      rate: Decimal.parse(rate.toString()),
      gstRate: gst,
      taxMode: mode,
    );
  }

  group('invoice discount amount', () {
    test('a discount that does not divide evenly still comes off the line', () {
      // The reported case: 10/300 is 0.0333..., which used to round to 0.03 and
      // leave the line taxable at 291 instead of 290.
      final result = GstEngine.computeDocument(
        lines: [line(id: 'l1', rate: 300)],
        split: GstSplit.interState,
        invoiceDiscountAmount: Decimal.parse('10'),
      );
      expect(result.invoiceDiscount, Decimal.parse('10'));
      expect(result.taxableValue, Decimal.parse('290'));
    });

    test('a one-rupee discount is not rounded away', () {
      // 1/300 is 0.00333..., which used to round to 0.00 and discount nothing.
      final result = GstEngine.computeDocument(
        lines: [line(id: 'l1', rate: 300)],
        split: GstSplit.interState,
        invoiceDiscountAmount: Decimal.parse('1'),
      );
      expect(result.invoiceDiscount, Decimal.parse('1'));
      expect(result.taxableValue, Decimal.parse('299'));
    });

    test('the tax is computed on the discounted value', () {
      // 290 at 18% is 52.20; the old ratio put the taxable at 291 and made the
      // tax 52.38, so the grand total was a rupee too high.
      final result = GstEngine.computeDocument(
        lines: [line(id: 'l1', rate: 300, gst: 18)],
        split: GstSplit.interState,
        invoiceDiscountAmount: Decimal.parse('10'),
      );
      expect(result.taxableValue, Decimal.parse('290'));
      expect(result.igstTotal, Decimal.parse('52.20'));
    });

    test('apportions across lines without inventing or losing a paisa', () {
      // ₹10 across lines of ₹100, ₹200 and ₹300 is 1/6, 1/3 and 1/2 of the bill
      // — none of which terminates.
      final result = GstEngine.computeDocument(
        lines: [
          line(id: 'a', rate: 100),
          line(id: 'b', rate: 200),
          line(id: 'c', rate: 300),
        ],
        split: GstSplit.interState,
        invoiceDiscountAmount: Decimal.parse('10'),
      );

      // Largest fractional remainder first: 1/6 keeps its discarded paisa.
      expect(result.lines.map((l) => l.taxableValue).toList(), [
        Decimal.parse('98.33'),
        Decimal.parse('196.67'),
        Decimal.parse('295.00'),
      ]);
      // This is the identity the PDF, the detail screen and the round-off all
      // assume: subtotal - discount == taxable.
      expect(
        result.subTotal - result.invoiceDiscount,
        Decimal.parse('590'),
      );
      expect(result.taxableValue, Decimal.parse('590'));
    });

    test('never discounts a line past its own value', () {
      // A discount that nearly wipes out the bill, spread over uneven lines.
      final lines = [
        line(id: 'a', rate: 100),
        line(id: 'b', rate: 200),
        line(id: 'c', rate: 300),
      ];
      final result = GstEngine.computeDocument(
        lines: lines,
        split: GstSplit.interState,
        invoiceDiscountAmount: Decimal.parse('599'),
      );
      expect(result.taxableValue, Decimal.parse('1'));
      for (final computed in result.lines) {
        expect(computed.taxableValue >= Decimal.zero, isTrue);
      }
    });
  });

  group('invoice discount percent', () {
    test('a clean percentage still comes off in full', () {
      final result = GstEngine.computeDocument(
        lines: [line(id: 'l1', rate: 1000)],
        split: GstSplit.interState,
        invoiceDiscountPercent: Decimal.fromInt(10),
      );
      expect(result.invoiceDiscount, Decimal.parse('100'));
      expect(result.taxableValue, Decimal.parse('900'));
    });

    test('settles a percentage that does not land on a paisa', () {
      // 7.5% of 299.97 is 22.49775. The discount is rounded to paisa (22.50) so
      // the printed total is a real money amount and the taxable still equals
      // subtotal - discount exactly.
      final result = GstEngine.computeDocument(
        lines: [line(id: 'l1', rate: 99.99, qty: 3)],
        split: GstSplit.interState,
        invoiceDiscountPercent: Decimal.parse('7.5'),
      );
      expect(result.subTotal, Decimal.parse('299.97'));
      expect(result.invoiceDiscount, Decimal.parse('22.50'));
      expect(
        result.subTotal - result.invoiceDiscount,
        Decimal.parse('277.47'),
      );
      expect(result.taxableValue, Decimal.parse('277.47'));
    });
  });
}
