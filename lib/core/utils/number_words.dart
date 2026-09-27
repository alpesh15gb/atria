/// Converts numbers to words using the Indian numbering system
/// (lakh / crore), as required on Indian invoices.
class NumberToWords {
  NumberToWords._();

  static const List<String> _ones = [
    '',
    'One',
    'Two',
    'Three',
    'Four',
    'Five',
    'Six',
    'Seven',
    'Eight',
    'Nine',
    'Ten',
    'Eleven',
    'Twelve',
    'Thirteen',
    'Fourteen',
    'Fifteen',
    'Sixteen',
    'Seventeen',
    'Eighteen',
    'Nineteen',
  ];

  static const List<String> _tens = [
    '',
    '',
    'Twenty',
    'Thirty',
    'Forty',
    'Fifty',
    'Sixty',
    'Seventy',
    'Eighty',
    'Ninety',
  ];

  /// "Rupees Twelve Lakh Thirty Four Thousand Five Hundred and Sixty Seven
  /// and Fifty Six Paise only" — paise included when the amount has any.
  static String indianCurrency(num value, {String prefix = 'Rupees'}) {
    if (value == 0) return '$prefix Zero only';
    final isNegative = value < 0;
    final abs = value.abs();
    // Work in paise (integers) so a rupee amount's fraction is exact.
    final totalPaise = (abs * 100).round();
    final rupees = totalPaise ~/ 100;
    final paise = totalPaise % 100;

    final parts = <String>[];
    if (rupees > 0 || paise == 0) {
      final words = _convertIndian(rupees);
      parts.add(words.isEmpty ? 'Zero' : words);
    }
    if (paise > 0) {
      parts.add('and ${_twoDigit(paise)} Paise');
    }
    final result = '$prefix ${parts.join(' ')} only';
    return isNegative ? 'Minus $result' : result;
  }

  static String _convertIndian(int value) {
    if (value == 0) return '';

    final crore = value ~/ 10000000;
    var rest = value % 10000000;
    final lakh = rest ~/ 100000;
    rest = rest % 100000;
    final thousand = rest ~/ 1000;
    rest = rest % 1000;
    final hundred = rest ~/ 100;
    final tensAndOnes = rest % 100;

    final parts = <String>[];
    if (crore > 0) {
      parts.add('${_twoDigit(crore)} Crore');
    }
    if (lakh > 0) {
      parts.add('${_twoDigit(lakh)} Lakh');
    }
    if (thousand > 0) {
      parts.add('${_twoDigit(thousand)} Thousand');
    }
    if (hundred > 0) {
      parts.add('${_ones[hundred]} Hundred');
    }
    if (tensAndOnes > 0) {
      parts.add(_twoDigit(tensAndOnes));
    }
    return parts.join(' ').trim();
  }

  static String _twoDigit(int value) {
    if (value < 20) return _ones[value];
    final t = value ~/ 10;
    final o = value % 10;
    return o == 0 ? _tens[t] : '${_tens[t]} ${_ones[o]}';
  }
}
