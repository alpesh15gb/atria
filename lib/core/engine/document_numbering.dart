/// Indian financial year and document-number utilities.
///
/// The Indian FY runs 1 April → 31 March. Most businesses number invoices per
/// FY ("INV/2025-26/001"), which Vyapar and My Bill Book both support.
class FinancialYear {
  final int startYear;
  final int endYear;

  const FinancialYear({required this.startYear, required this.endYear});

  /// The FY containing [date].
  factory FinancialYear.forDate(DateTime date) {
    if (date.month >= DateTime.april) {
      return FinancialYear(startYear: date.year, endYear: date.year + 1);
    }
    return FinancialYear(startYear: date.year - 1, endYear: date.year);
  }

  factory FinancialYear.current() => FinancialYear.forDate(DateTime.now());

  DateTime get start => DateTime(startYear, DateTime.april, 1);
  DateTime get end => DateTime(endYear, DateTime.march, 31, 23, 59, 59);

  bool contains(DateTime date) =>
      !date.isBefore(start) && !date.isAfter(end);

  /// "2025-26"
  String get shortLabel => '$startYear-${endYear.toString().substring(2)}';

  /// "FY 2025-26"
  String get label => 'FY $shortLabel';

  @override
  String toString() => label;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FinancialYear &&
          startYear == other.startYear &&
          endYear == other.endYear;

  @override
  int get hashCode => startYear.hashCode ^ endYear.hashCode;
}

enum NumberingStyle {
  /// "INV-001"
  simple('Simple (INV-001)'),
  /// "INV/2025-26/001"
  financialYear('Financial year (INV/2025-26/001)'),
  /// "INV/2025-26/001/A" — suffix branch for series
  withSuffix('Financial year + series (INV/2025-26/001/A)');

  final String label;
  const NumberingStyle(this.label);
}

class DocumentNumbering {
  DocumentNumbering._();

  /// Formats a document number.
  ///
  /// [sequence] is 1-based. [padding] zeroes the sequence to that width.
  static String format({
    required String prefix,
    required int sequence,
    required NumberingStyle style,
    DateTime? date,
    String suffix = '',
    int padding = 3,
  }) {
    final when = date ?? DateTime.now();
    final padded = sequence.toString().padLeft(padding, '0');
    switch (style) {
      case NumberingStyle.simple:
        return suffix.isEmpty
            ? '$prefix-$padded'
            : '$prefix-$padded-$suffix';
      case NumberingStyle.financialYear:
        final fy = FinancialYear.forDate(when);
        return suffix.isEmpty
            ? '$prefix/${fy.shortLabel}/$padded'
            : '$prefix/${fy.shortLabel}/$padded/$suffix';
      case NumberingStyle.withSuffix:
        final fy = FinancialYear.forDate(when);
        final s = suffix.isEmpty ? 'A' : suffix;
        return '$prefix/${fy.shortLabel}/$padded/$s';
    }
  }

  /// Parses the sequence number back out of a formatted document number (best
  /// effort), or null when there is none to read.
  ///
  /// Every style [format] produces puts the counter in the **last** numeric
  /// segment — "INV-001" and "INV/2025-26/001" both answer 1 — so the segments
  /// are scanned from the end and the first one that is entirely digits wins.
  /// The previous scan ran from the *front*, which made a financial-year number
  /// answer 2025: the year is the second segment, not the counter.
  ///
  /// A series suffix is the one thing that cannot be told apart from the
  /// counter when it is itself numeric ("INV/2025-26/001/2" answers 2); a
  /// lettered one is skipped over.
  static int? parseSequence(String value) {
    for (final part in value.split(RegExp('[/-]')).reversed) {
      final n = int.tryParse(part.trim());
      if (n != null) return n;
    }
    return null;
  }
}
