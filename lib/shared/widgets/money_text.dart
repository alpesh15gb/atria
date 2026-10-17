import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';

/// Renders an amount with the correct semantic color: green for money in,
/// red for money out. Accounting apps live and die by this convention.
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.amount, {
    super.key,
    this.style,
    this.showSymbol = true,
    this.signMode = MoneySignMode.never,
    this.compact = false,
    this.colorize = true,
    this.decimals = 2,
    this.textAlign = TextAlign.left,
    this.shrinkToFit = false,
  });

  final Decimal amount;
  final TextStyle? style;
  final bool showSymbol;
  final MoneySignMode signMode;
  final bool compact;
  final bool colorize;
  final int decimals;

  /// How the figure sits in a column wider than itself. Tables right-align
  /// their figures under right-aligned headers; a bare [Text] is left-aligned
  /// and the column reads as skewed.
  final TextAlign textAlign;

  /// Scales the figure down to fit the width it is given instead of
  /// overflowing or truncating it.
  ///
  /// Both alternatives to this are wrong in a books app. An ellipsis turns
  /// `₹1,23,456.00` into `₹1,23,45…`, so the reader cannot check the figure —
  /// and a RenderFlex overflow throws a yellow stripe across the totals on
  /// every phone narrower than about 380dp. Scaling keeps every digit legible
  /// and shrinks only until it fits, so a wide window is unaffected.
  final bool shrinkToFit;

  @override
  Widget build(BuildContext context) {
    final colors = atriaColors(context);
    final negative = amount < Decimal.zero;
    final sign = signMode == MoneySignMode.always
        ? (negative ? '-' : '+')
        : (signMode == MoneySignMode.auto && negative)
        ? '-'
        : '';

    // For `never` we rely on the formatter's own minus sign, so the value
    // must go in un-negated-of-magnitude: passing the magnitude here would
    // strip the sign and render a refund as a red-but-positive number.
    final String text;
    if (signMode == MoneySignMode.never) {
      text = compact
          ? Formatters.moneyCompact(amount)
          : Formatters.money(
              amount,
              showSymbol: showSymbol,
              decimals: decimals,
            );
    } else {
      final magnitude = negative ? -amount : amount;
      final magnitudeText = compact
          ? Formatters.moneyCompact(magnitude)
          : Formatters.money(
              magnitude,
              showSymbol: showSymbol,
              decimals: decimals,
            );
      text = '$sign$magnitudeText';
    }
    final display = text;

    Color? color;
    if (colorize) {
      if (amount < Decimal.zero) {
        color = colors.negative;
      } else if (amount > Decimal.zero && signMode == MoneySignMode.always) {
        color = colors.positive;
      }
    }

    final figure = Text(
      display,
      textAlign: textAlign,
      style: (style ?? Theme.of(context).textTheme.titleMedium)?.copyWith(
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
        fontFamilyFallback: const ['Inter'],
      ),
    );

    if (!shrinkToFit) return figure;
    // `scaleDown` never grows the figure past its natural size, so the desktop
    // layout is untouched — only a box too small for the text is accommodated.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: _fitAlignment(textAlign),
      child: figure,
    );
  }

  Alignment _fitAlignment(TextAlign align) => switch (align) {
    TextAlign.right || TextAlign.end => Alignment.centerRight,
    TextAlign.center => Alignment.center,
    _ => Alignment.centerLeft,
  };
}

enum MoneySignMode {
  /// Never show a leading sign (uses the minus from formatting only).
  never,

  /// Show + or - based on the value.
  auto,

  /// Always show a sign, even for positive amounts (ledger style).
  always,
}
