import 'package:decimal/decimal.dart';

import '../../utils/money.dart';

/// One movement as the costing engine sees it.
///
/// Deliberately not the drift entity: the engine is pure arithmetic over a
/// list, so it can be tested with hand-written rows and no database at all —
/// and the backfill, the report and the writer must all agree by construction,
/// not by each calling the other's code.
class CostedMovement {
  const CostedMovement({
    required this.id,
    required this.kind,
    required this.quantity,
    this.unitCost,
  });

  final String id;

  /// opening | purchase | purchase_return | sale | sale_return | adjustment
  final String kind;

  /// Signed: negative leaves stock, positive brings it in.
  final double quantity;

  /// The cost already recorded on this row, or null if it has none (a movement
  /// written before costing existed).
  final Decimal? unitCost;

  bool get isInbound => quantity > 0;
}

/// The running cost of one item at one point in the log.
///
/// A value type with no database behind it, because this is where the two
/// rules that are easy to get subtly wrong live:
///
///  * **the accumulator is never rounded.** It stays at 4 decimal places
///    through the whole run and only the *reported* unit cost is rounded.
///    Rounding a moving average after every movement drifts by tens of paise a
///    year — and drift in a stock valuation is a number that never agrees with
///    the physical count.
///  * **negative stock never divides.** A shop may bill before it buys (the
///    ledger deliberately permits it), which makes the balance negative and
///    `value / quantity` a negative cost. A negative cost turns every margin
///    downstream upside down: goods appear to have been sold at a profit while
///    the shop is losing money on them. So the last known good average is
///    carried forward and the row is flagged.
class MovingAverageCosting {
  MovingAverageCosting._({
    required this.quantity,
    required this.value,
    required this.lastGoodAverage,
    required this.usedFallback,
  });

  /// A fresh accumulator: nothing in stock, nothing known about its cost.
  factory MovingAverageCosting.initial() => MovingAverageCosting._(
    quantity: Decimal.zero,
    value: Decimal.zero,
    lastGoodAverage: null,
    usedFallback: false,
  );

  final Decimal quantity;
  final Decimal value;

  /// The most recent average derived from a positive balance. Null until the
  /// first inbound movement.
  final Decimal? lastGoodAverage;

  /// Whether the average returned by [average] is a carried-forward figure
  /// rather than one computed from the current balance.
  final bool usedFallback;

  /// The cost per unit right now.
  Decimal? get average {
    if (quantity > Decimal.zero && value > Decimal.zero) {
      return _ratio(value, quantity);
    }
    return lastGoodAverage;
  }

  /// Applies one movement, returning the new state and the cost to stamp on
  /// this row.
  ///
  /// The stamped cost is what the row *consumed*, so replaying the log from
  /// this stamp reproduces the same numbers. For an outbound movement that is
  /// the average before it; for an inbound one, the cost the goods came in at.
  (MovingAverageCosting, Decimal?) apply(CostedMovement movement) {
    final qty = Money.of(movement.quantity);
    final before = average;

    if (movement.quantity == 0) {
      // A zero-quantity movement is legal (a transfer of nothing, a
      // placeholder line) and must not change the average. It still gets a
      // stamp so a report can show what it valued at.
      return (_copy(usedFallback: false), before);
    }

    if (movement.isInbound) {
      // Inbound cost: what the line actually cost, excluding recoverable tax.
      // A movement with no recorded cost falls back to the running average and
      // is flagged — better a slightly wrong known cost than a zero that would
      // wipe the average out entirely.
      final stamped = movement.unitCost ?? before ?? Decimal.zero;
      final fromFallback = movement.unitCost == null && before != null;
      final newQty = quantity + qty;
      final newValue = value + (qty * stamped);
      final next = _copy(
        quantity: newQty,
        value: newValue,
        lastGoodAverage: _averageOf(newQty, newValue) ?? lastGoodAverage,
        usedFallback: fromFallback,
      );
      return (next, stamped);
    }

    // Outbound. Stock leaves at the average that applied *before* it left.
    // If there is no average to speak of — the item has never been bought, or
    // was given away — the movement is valued at zero and that is recorded
    // honestly rather than guessed at.
    final stamped = before ?? movement.unitCost ?? Decimal.zero;
    final newQty = quantity + qty;
    final newValue = value + (qty * stamped);
    if (newQty <= Decimal.zero) {
      // Stock has hit zero, or gone negative because the shop billed before it
      // bought. Either way the average stops meaning anything here, and the
      // value is *not* forced up to zero: the oversold quantity is a real
      // liability at the cost it was valued at, and carrying it means the next
      // purchase is re-averaged against what the shop has actually net paid.
      // Zeroing it would value the replacement goods at the full invoice price
      // as though the shortfall had cost nothing.
      //
      // The last good average is kept either way, so the next purchase has
      // something to fall back on rather than starting from nothing — and
      // [usedFallback] is true, because that is exactly what `average` is now
      // returning: a carried-forward figure, not one this balance supports.
      return (
        _copy(
          quantity: newQty,
          value: newValue > Decimal.zero ? Decimal.zero : newValue,
          lastGoodAverage: lastGoodAverage,
          usedFallback: lastGoodAverage != null,
        ),
        stamped,
      );
    }
    final next = _copy(
      quantity: newQty,
      value: newValue,
      lastGoodAverage: _averageOf(newQty, newValue) ?? lastGoodAverage,
      usedFallback: false,
    );
    return (next, stamped);
  }

  /// The reported unit cost — rounded once, at the end.
  static Decimal? report(Decimal? average) =>
      average == null ? null : Money.roundTo(average, places: 2);

  MovingAverageCosting _copy({
    Decimal? quantity,
    Decimal? value,
    Decimal? lastGoodAverage,
    bool? usedFallback,
  }) => MovingAverageCosting._(
    quantity: quantity ?? this.quantity,
    value: value ?? this.value,
    lastGoodAverage: lastGoodAverage ?? this.lastGoodAverage,
    usedFallback: usedFallback ?? this.usedFallback,
  );

  /// The average implied by a balance — null when it is undefined (zero or
  /// negative quantity), which is the whole reason [average] has a fallback.
  static Decimal? _averageOf(Decimal qty, Decimal value) {
    if (qty <= Decimal.zero || value <= Decimal.zero) return null;
    return _ratio(value, qty);
  }
}

/// Divides and rounds in one step.
///
/// `Decimal`'s `/` returns a `Rational`, which is not a `Decimal` and cannot be
/// stored as one — so every division here goes through a helper that fixes the
/// scale once. The 4 places are the accumulator's precision, not a display
/// choice: this value is carried forward into the next movement.
Decimal _ratio(Decimal value, Decimal quantity, {int places = 4}) =>
    (value / quantity).toDecimal(scaleOnInfinitePrecision: places);

/// Replays a movement log to produce the cost each row should carry.
///
/// [moves] must already be in the order they happened — the caller sorts by
/// `date, rowid`, because two movements in the same microsecond have no other
/// order and the average depends on which came first.
///
/// Returns the id → cost map for every row, including rows that already had a
/// cost: recomputing them is what makes the backfill idempotent and safe to
/// re-run after a bug fix.
Map<String, Decimal> replay(List<CostedMovement> moves) {
  var costing = MovingAverageCosting.initial();
  final out = <String, Decimal>{};
  for (final move in moves) {
    final (next, stamped) = costing.apply(move);
    costing = next;
    out[move.id] = stamped ?? Decimal.zero;
  }
  return out;
}
