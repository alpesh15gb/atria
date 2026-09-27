import 'package:decimal/decimal.dart';

/// Indian number-system money helpers.
///
/// Uses [Decimal] everywhere: financial math must never touch doubles.
/// Grouping follows the Indian convention (…,00,00,000) rather than the
/// Western (…,000,000).
class Money {
  Money._();

  static const int scale = 2;

  /// Zero, as a [Decimal]. `Decimal.zero` is `static final` rather than
  /// `const` in package:decimal, so it can't be used as a compile-time
  /// default value — use a nullable parameter and resolve it inside instead.
  static final Decimal zero = Decimal.zero;

  /// Parses a user-entered amount string into [Decimal].
  /// Accepts Indian grouping commas ("1,00,000"), spaces, ₹ and a leading +/-.
  static Decimal? tryParse(String? input) {
    if (input == null) return null;
    var s = input.trim();
    if (s.isEmpty) return null;
    s = s.replaceAll(RegExp(r'[\s₹,]'), '');
    if (s.isEmpty) return null;
    if (s == '-' || s == '+') return null;
    try {
      return Decimal.parse(s);
    } catch (_) {
      return null;
    }
  }

  /// Parses [input], THROWING [FormatException] when it isn't a valid
  /// amount.
  ///
  /// The old behaviour silently returned 0 for malformed input — a typo in
  /// an item price or expense amount became a ₹0 record with no warning.
  /// Callers that want a silent fallback still have [fallback] and
  /// [tryParse]; the throw is the default so new call sites are safe.
  static Decimal parse(String input, {Decimal? fallback}) {
    final parsed = tryParse(input);
    if (parsed != null) return parsed;
    if (fallback != null) return fallback;
    throw FormatException('"$input" is not a valid amount.');
  }

  static Decimal of(num value) => Decimal.parse(value.toString());

  /// Rounds to 2 decimal places using HALF_UP (accounting rounding).
  static Decimal round2(Decimal value) => value.round(scale: scale);

  /// Rounds to [places], HALF_UP, returning a [Decimal].
  static Decimal roundTo(Decimal value, {int places = scale}) =>
      value.round(scale: places);

  /// Percent of [value] at [rate]%, rounded to scale.
  static Decimal percent(Decimal value, num rate) => round2(
      (value * Decimal.parse(rate.toString()) / Decimal.fromInt(100))
          .toDecimal(scaleOnInfinitePrecision: scale));

  /// [value] divided by 100 as a [Decimal].
  static Decimal over100(Decimal value) =>
      (value / Decimal.fromInt(100)).toDecimal(scaleOnInfinitePrecision: scale);

  // ---- Arithmetic ----
  static Decimal add(Decimal a, Decimal b) => a + b;
  static Decimal sub(Decimal a, Decimal b) => a - b;
  static Decimal mul(Decimal a, Decimal b) => a * b;
  static Decimal mulN(Decimal a, num b) => a * Decimal.parse(b.toString());
  /// [value] divided by [b] as a [Decimal], rounded HALF_UP to scale.
  ///
  /// `Rational.toDecimal` TRUNCATES by default, which silently loses a paisa
  /// on divisors that aren't a power of 10 (200 / 3 -> 66.66, not 66.67).
  /// Rounding via [toBigInt] keeps exact accounting math.
  static Decimal div(Decimal a, Decimal b) => (a / b).toDecimal(
      scaleOnInfinitePrecision: scale, toBigInt: (v) => v.round());
  static Decimal divN(Decimal a, num b) =>
      (a / Decimal.parse(b.toString())).toDecimal(
          scaleOnInfinitePrecision: scale, toBigInt: (v) => v.round());

  static Decimal sum(Iterable<Decimal> values) {
    var total = Decimal.zero;
    for (final v in values) {
      total += v;
    }
    return total;
  }

  static bool isNegative(Decimal value) => value < Decimal.zero;
  static bool isZero(Decimal value) => value == Decimal.zero;

  /// `true` when [value] is below zero. Mirrors the `num.isNegative` API so
  /// call sites read naturally.
  static bool negative(Decimal value) => value < Decimal.zero;

  /// Returns [value] negated (used for display of credits).
  static Decimal abs(Decimal value) => value < Decimal.zero ? -value : value;
}
