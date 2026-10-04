import 'package:atria/core/utils/number_words.dart';
import 'package:atria/core/engine/document_numbering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two pure number helpers that print themselves on an invoice: the amount
/// in words and the document number. Both had no coverage at all, which is how
/// two quiet defects survived — `indianCurrency` threw a `RangeError` on any
/// total of ₹100 crore or more (the PDF and the statement export both call it),
/// and `parseSequence` answered 2025 for "INV/2025-26/001" because it read the
/// first numeric segment, which is the financial year.
///
/// `flutter test` was originally blocked by an application-control policy, so
/// these expectations were first pinned from a compiled snapshot. They are run
/// here, and the strings are verbatim output — never guesses.
void main() {
  group('amount in words (Indian system)', () {
    test('the small cases that were already correct stay put', () {
      expect(NumberToWords.indianCurrency(0), 'Rupees Zero only');
      expect(NumberToWords.indianCurrency(1), 'Rupees One only');
      expect(NumberToWords.indianCurrency(7), 'Rupees Seven only');
      expect(NumberToWords.indianCurrency(15), 'Rupees Fifteen only');
      expect(NumberToWords.indianCurrency(20), 'Rupees Twenty only');
      expect(NumberToWords.indianCurrency(99), 'Rupees Ninety Nine only');
      expect(NumberToWords.indianCurrency(1180),
          'Rupees One Thousand One Hundred Eighty only');
      expect(NumberToWords.indianCurrency(1234),
          'Rupees One Thousand Two Hundred Thirty Four only');
      expect(NumberToWords.indianCurrency(99999),
          'Rupees Ninety Nine Thousand Nine Hundred Ninety Nine only');
      expect(NumberToWords.indianCurrency(100000), 'Rupees One Lakh only');
      expect(NumberToWords.indianCurrency(1234567),
          'Rupees Twelve Lakh Thirty Four Thousand Five Hundred Sixty Seven '
          'only');
      expect(NumberToWords.indianCurrency(12000000),
          'Rupees One Crore Twenty Lakh only');
      // The boundary of the old bug: 99 crore — ₹99,99,99,999 — was the
      // largest that worked, because `_tens[t]` threw for any crore count of
      // 100 and up.
      expect(NumberToWords.indianCurrency(999999999),
          'Rupees Ninety Nine Crore Ninety Nine Lakh Ninety Nine Thousand Nine '
          'Hundred Ninety Nine only');
    });

    test('a hundred crore and above no longer throws', () {
      // Every one of these raised
      // "RangeError (length): Invalid value: Not in inclusive range 0..9".
      // 100 crore = 1,00,00,00,000 — the smallest total that used to throw.
      expect(NumberToWords.indianCurrency(1000000000),
          'Rupees One Hundred Crore only');
      expect(NumberToWords.indianCurrency(1230000000),
          'Rupees One Hundred Twenty Three Crore only');
      // A crore head alongside every smaller group: 12,34,56,789.
      expect(NumberToWords.indianCurrency(123456789),
          'Rupees Twelve Crore Thirty Four Lakh Fifty Six Thousand Seven '
          'Hundred Eighty Nine only');
      expect(NumberToWords.indianCurrency(1234567890),
          'Rupees One Hundred Twenty Three Crore Forty Five Lakh Sixty Seven '
          'Thousand Eight Hundred Ninety only');
      expect(NumberToWords.indianCurrency(12345678),
          'Rupees One Crore Twenty Three Lakh Forty Five Thousand Six Hundred '
          'Seventy Eight only');
      // A thousand crores and up, where the crore head is itself grouped:
      // 1,000 crore, 10,000 crore, then 1,00,000 crore.
      expect(NumberToWords.indianCurrency(10000000000),
          'Rupees One Thousand Crore only');
      expect(NumberToWords.indianCurrency(100000000000),
          'Rupees Ten Thousand Crore only');
      expect(NumberToWords.indianCurrency(1000000000000),
          'Rupees One Lakh Crore only');
    });

    test('nothing from zero up to a hundred thousand crore throws', () {
      // The old `_twoDigit` was only ever asked for a number below 100 and
      // indexed `_tens[t]` blind, so the whole risk was the unbounded crore
      // head. Sweep every total up to a lakh, then every crore count with a
      // worst-case tail of the smaller groups.
      for (var v = 0; v <= 100000; v++) {
        expect(() => NumberToWords.indianCurrency(v), returnsNormally,
            reason: '₹$v threw');
      }
      for (var crore = 0; crore <= 100000; crore++) {
        for (final tail in const [
          0,
          9999999,
          4999999,
          100000,
          1,
        ]) {
          final v = crore * 10000000 + tail;
          expect(() => NumberToWords.indianCurrency(v), returnsNormally,
              reason: '₹$v threw');
        }
      }
    });

    test('the crore head is read in Indian words, never pluralised', () {
      // "One Hundred Crore", not "One Hundred Crores", and not a digit-word
      // mix like "1 Hundred".
      for (final crore in const [1, 2, 10, 19, 20, 42, 99, 100, 101, 999, 1000]) {
        final words = NumberToWords.indianCurrency(crore * 10000000);
        expect(words, endsWith(' Crore only'), reason: '₹$crore crore: $words');
        expect(words, isNot(contains('Crores')));
        expect(words, isNot(matches(RegExp(r'\d'))));
      }
    });

    test('paise and a negative total read the way they always have', () {
      expect(NumberToWords.indianCurrency(12.34),
          'Rupees Twelve and Thirty Four Paise only');
      expect(NumberToWords.indianCurrency(99.99),
          'Rupees Ninety Nine and Ninety Nine Paise only');
      expect(NumberToWords.indianCurrency(-45.5),
          'Minus Rupees Forty Five and Fifty Paise only');
      // A crore count with paise attached takes the same path.
      expect(NumberToWords.indianCurrency(1000000000.05),
          'Rupees One Hundred Crore and Five Paise only');
    });
  });

  group('document numbering', () {
    test('reads the counter, not the financial year', () {
      // The bug: 2025 (the FY) came back for every FY-styled number.
      expect(DocumentNumbering.parseSequence('INV/2025-26/001'), 1);
      expect(DocumentNumbering.parseSequence('INV/2025-26/009'), 9);
      expect(DocumentNumbering.parseSequence('INV/2025-26/001/A'), 1);
      expect(DocumentNumbering.parseSequence('INV-001'), 1);
      expect(DocumentNumbering.parseSequence('INV-0009'), 9);
      expect(DocumentNumbering.parseSequence('INV-001-A'), 1);
      expect(DocumentNumbering.parseSequence('SO-2025-26-004'), 4);
      expect(DocumentNumbering.parseSequence('001'), 1);
    });

    test('a number with no counter in it answers null', () {
      expect(DocumentNumbering.parseSequence('INV'), isNull);
      expect(DocumentNumbering.parseSequence(''), isNull);
    });

    test('every numbering style survives a format/parse round trip', () {
      for (final style in NumberingStyle.values) {
        for (final sequence in [1, 42, 999]) {
          final number = DocumentNumbering.format(
            prefix: 'INV',
            sequence: sequence,
            style: style,
            date: DateTime(2026, 5, 4),
            suffix: style == NumberingStyle.withSuffix ? 'B' : '',
          );
          expect(DocumentNumbering.parseSequence(number), sequence,
              reason: 'style $style produced "$number"');
        }
      }
    });
  });
}