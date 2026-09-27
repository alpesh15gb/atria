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

  /// Parses a sequence number out of a formatted document number (best
  /// effort): the first / last numeric segment. Used by the seeder and
  /// diagnostics to extract the running counter from existing numbers.
  static int? parseSequence(String value) {
    final parts = value.split('/');
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n != null) return n;
    }
    final dashParts = value.split('-');
    for (final part in dashParts.reversed) {
      final n = int.tryParse(part);
      if (n != null) return n;
    }
    return null;
  }
}
