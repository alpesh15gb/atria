import 'package:atria/core/utils/formatters.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

/// The compact form is what the dashboard cards show, so its conventions are
/// user-visible: a shopkeeper reading "₹12.35 K" on their receivables card has
/// to stop and do arithmetic to learn what they are owed.

void main() {
  test('compact uses lakh and crore, not thousands', () {
    // "K" is not an Indian unit, and rounding 12,345 up to 12.35 K both loses
    // the exact figure and reads like a percentage.
    expect(Formatters.moneyCompact(Decimal.fromInt(12345)), '₹12,345');
    expect(Formatters.moneyCompact(Decimal.fromInt(999)), '₹999');
  });

  test('lakh and crore trim trailing zeros', () {
    expect(Formatters.moneyCompact(Decimal.fromInt(150000)), '₹1.5 L');
    expect(Formatters.moneyCompact(Decimal.fromInt(100000)), '₹1 L');
    expect(Formatters.moneyCompact(Decimal.fromInt(12000000)), '₹1.2 Cr');
  });

  test('compact is never lossy at the round number', () {
    // The grouped figure is exact; the compact one is only for the cards.
    expect(Formatters.moneyCompact(Decimal.fromInt(12345678)), '₹1.23 Cr');
  });

  test('compact keeps the sign', () {
    expect(Formatters.moneyCompact(-Decimal.fromInt(150000)), '-₹1.5 L');
    expect(Formatters.moneyCompact(-Decimal.fromInt(12345)), '-₹12,345');
  });
}
