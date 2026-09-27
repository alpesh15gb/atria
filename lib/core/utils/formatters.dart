import 'package:decimal/decimal.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../constants/app_constants.dart';

/// Formatting helpers for Indian locale output.
class Formatters {
  Formatters._();

  /// Groups a numeric string using the Indian convention: rightmost group of
  /// 3, then groups of 2 (e.g. 1234567.89 -> "12,34,567.89").
  static String indianGroup(String value) {
    final parts = value.split('.');
    final isNeg = parts[0].startsWith('-');
    var intPart = isNeg ? parts[0].substring(1) : parts[0];
    final decPart = parts.length > 1 ? parts[1] : '';

    // Indian grouping: rightmost group of 3, then groups of 2 going left.
    // The first comma fires after 3 digits; every comma after that fires
    // after 2. (A plain "every 2" loop mis-groups 1234 as "12,34".)
    final buffer = StringBuffer();
    bool firstGroup = true;
    int count = 0;
    for (int i = intPart.length - 1; i >= 0; i--) {
      buffer.write(intPart[i]);
      count++;
      if (i > 0) {
        final needed = firstGroup ? 3 : 2;
        if (count == needed) {
          buffer.write(',');
          count = 0;
          firstGroup = false;
        }
      }
    }
    final grouped = buffer.toString().split('').reversed.join();
    final sign = isNeg ? '-' : '';
    final dec = decPart.isEmpty ? '' : '.$decPart';
    return '$sign$grouped$dec';
  }

  /// "₹1,23,456.78". Always shows 2 decimals for amounts.
  static String money(
    Decimal value, {
    String symbol = AppConstants.currencySymbol,
    bool showSymbol = true,
    int decimals = 2,
  }) {
    // toStringAsFixed pads trailing zeros — Decimal.round returns the value
    // unchanged when its own scale is already <= `decimals`, and toString()
    // would then render "100" instead of "100.00".
    final scaled = value.round(scale: decimals);
    final grouped = indianGroup(scaled.toStringAsFixed(decimals));
    final isNeg = scaled < Decimal.zero;
    final sign = isNeg ? '-' : '';
    final body = isNeg
        ? grouped.substring(1) // strip the minus, re-attach before symbol
        : grouped;
    return showSymbol ? '$sign$symbol$body' : '$sign$body';
  }

  /// Compact Indian money: "₹1.2 L", "₹3.4 Cr", "₹12,345".
  static String moneyCompact(Decimal value,
      {String symbol = AppConstants.currencySymbol}) {
    final abs = value < Decimal.zero ? -value : value;
    final crore = _div(abs, 10000000);
    final lakh = _div(abs, 100000);
    final thousand = _div(abs, 1000);

    String compact;
    if (crore >= Decimal.one) {
      compact = '${_trim(crore)} Cr';
    } else if (lakh >= Decimal.one) {
      compact = '${_trim(lakh)} L';
    } else if (thousand >= Decimal.one) {
      compact = '${_trim(thousand)} K';
    } else {
      compact = indianGroup(abs.round(scale: 0).toStringAsFixed(0));
    }
    return value < Decimal.zero ? '-$symbol$compact' : '$symbol$compact';
  }

  /// Exact division to a [Decimal] (drift's `/` yields a [Rational]).
  static Decimal _div(Decimal value, int divisor) =>
      (value / Decimal.fromInt(divisor)).toDecimal(scaleOnInfinitePrecision: 4);

  static String _trim(Decimal value) {
    final rounded = value.round(scale: 2);
    final s = rounded.toString();
    if (s.contains('.')) {
      var out = s.replaceAll(RegExp(r'0+$'), '');
      out = out.replaceAll(RegExp(r'\.$'), '');
      return out.isEmpty ? '0' : out;
    }
    return s;
  }

  /// Signed amount for ledgers: "+ ₹500.00" / "- ₹500.00".
  static String moneySigned(Decimal value, {bool showSignWhenZero = false}) {
    if (value == Decimal.zero && !showSignWhenZero) {
      return money(value);
    }
    final prefix = value < Decimal.zero ? '-' : '+';
    return '$prefix ${money(value < Decimal.zero ? -value : value)}';
  }

  /// Plain number with 2dp and Indian grouping (no symbol).
  static String number(Decimal value, {int decimals = 2}) {
    return indianGroup(value.round(scale: decimals).toStringAsFixed(decimals));
  }

  /// Quantity formatting: trims trailing zeros ("12.00" -> "12", "12.50" -> "12.5").
  static String qty(Decimal value, {int maxDecimals = 3}) {
    var s = value.round(scale: maxDecimals).toString();
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '');
      s = s.replaceAll(RegExp(r'\.$'), '');
    }
    return s.isEmpty ? '0' : s;
  }

  /// Percentage with up to 2dp.
  static String percent(num value, {int decimals = 2}) {
    var s = value.toStringAsFixed(decimals);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '');
      s = s.replaceAll(RegExp(r'\.$'), '');
    }
    return '$s%';
  }

  // ---- Dates ----
  static final DateFormat _dmy = DateFormat('dd MMM yyyy');
  static final DateFormat _dmyTime = DateFormat('dd MMM yyyy, hh:mm a');
  static final DateFormat _ymd = DateFormat('yyyy-MM-dd');
  static final DateFormat _monthYear = DateFormat('MMM yyyy');
  static final DateFormat _monthDay = DateFormat('dd MMM');

  static String date(DateTime? value) =>
      value == null ? '-' : _dmy.format(value);
  static String dateTime(DateTime? value) =>
      value == null ? '-' : _dmyTime.format(value);
  static String isoDate(DateTime value) => _ymd.format(value);
  static String monthYear(DateTime value) => _monthYear.format(value);
  static String monthDay(DateTime value) => _monthDay.format(value);

  /// Human "x days ago" for recent activity.
  static String relative(DateTime value, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final diff = reference.difference(value);
    if (diff.isNegative) return 'just now';
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} hr ago';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 30) return '${diff.inDays} days ago';
    return date(value);
  }

  /// Truncates with an ellipsis.
  static String ellipsis(String value, int length) {
    if (value.length <= length) return value;
    return '${value.substring(0, length - 1)}…';
  }

  /// Capitalizes the first letter of each word.
  static String titleCase(String value) {
    if (value.trim().isEmpty) return value;
    return value
        .split(RegExp(r'\s+'))
        .map((w) => w.isEmpty
            ? w
            : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ');
  }

  /// Masks a phone/GSTIN for privacy in lists.
  static String mask(String value, {int visible = 4}) {
    if (value.length <= visible) return value;
    return '${'•' * (value.length - visible)}${value.substring(value.length - visible)}';
  }
}

/// TextInputFormatter that applies Indian grouping as the user types an amount.
class IndianAmountInputFormatter extends TextInputFormatter {
  final int decimals;

  IndianAmountInputFormatter({this.decimals = 2});

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text.replaceAll(RegExp(r'[^\d.]'), '');
    if (raw.isEmpty) {
      return TextEditingValue(
        text: '',
        selection: const TextSelection.collapsed(offset: 0),
      );
    }

    // Only allow a single decimal point.
    final dotIndex = raw.indexOf('.');
    String intPart;
    String decPart = '';
    if (dotIndex == -1) {
      intPart = raw;
    } else {
      intPart = raw.substring(0, dotIndex);
      decPart = raw.substring(dotIndex + 1);
    }
    if (decPart.length > decimals) {
      decPart = decPart.substring(0, decimals);
    }
    final grouped = Formatters.indianGroup(intPart);
    final text = decPart.isEmpty && raw.contains('.')
        ? '$grouped.'
        : decPart.isEmpty
            ? grouped
            : '$grouped.$decPart';

    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Forces uppercase for GSTIN/PAN entry.
class UpperCaseInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
