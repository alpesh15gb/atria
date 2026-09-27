import 'package:atria/core/constants/indian_states.dart';
import 'package:atria/core/engine/document_numbering.dart';
import 'package:atria/core/engine/gst_engine.dart';
import 'package:atria/core/utils/number_words.dart';
import 'package:atria/core/utils/validators.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GSTIN validation', () {
    test('accepts real GSTINs with valid checksums', () {
      // Google India + Indian Oil registrations across states.
      expect(Validators.isValidGstin('27AAGCG4576J1Z6'), isTrue);
      expect(Validators.isValidGstin('29AAACI1681G1ZL'), isTrue);
      expect(Validators.isValidGstin('12AAACI1681G1Z0'), isTrue);
      expect(Validators.isValidGstin('37AAACI1681G2ZN'), isTrue);
      expect(Validators.isValidGstin('38AAALS7119L1ZH'), isTrue);
    });

    test('rejects GSTINs with bad checksums or structure', () {
      expect(Validators.isValidGstin('27AAGCG4576J1Z8'), isFalse);
      expect(Validators.isValidGstin('47AAGCG4576J1A6'), isFalse);
      expect(Validators.isValidGstin('25AAACI1681G1Z4'), isFalse);
      expect(Validators.isValidGstin('1234'), isFalse);
      expect(Validators.isValidGstin('29AAACI1681G1Z0A'), isFalse);
    });

    test('is lenient about case and surrounding whitespace', () {
      expect(Validators.isValidGstin(' 27aagcg4576j1z6 '), isTrue);
    });
  });

  group('GstEngine', () {
    TaxLine line({
      double qty = 1,
      double rate = 1000,
      double gst = 18,
      TaxMode mode = TaxMode.exclusive,
    }) {
      return TaxLine(
        id: 'l1',
        name: 'Test item',
        quantity: Decimal.parse(qty.toString()),
        unit: 'pcs',
        rate: Decimal.parse(rate.toString()),
        gstRate: gst,
        taxMode: mode,
      );
    }

    test('intra-state splits tax equally into CGST and SGST', () {
      final result = GstEngine.computeDocument(
        lines: [line()],
        split: GstSplit.intraState,
      );
      expect(result.taxableValue, Decimal.parse('1000'));
      expect(result.cgstTotal, Decimal.parse('90'));
      expect(result.sgstTotal, Decimal.parse('90'));
      expect(result.igstTotal, Decimal.zero);
      expect(result.grandTotal, Decimal.parse('1180'));
    });

    test('inter-state charges IGST only', () {
      final result = GstEngine.computeDocument(
        lines: [line()],
        split: GstSplit.interState,
      );
      expect(result.cgstTotal, Decimal.zero);
      expect(result.sgstTotal, Decimal.zero);
      expect(result.igstTotal, Decimal.parse('180'));
      expect(result.grandTotal, Decimal.parse('1180'));
    });

    test('inclusive tax back-calculates the taxable value', () {
      final result = GstEngine.computeDocument(
        lines: [line(rate: 1180, mode: TaxMode.inclusive)],
        split: GstSplit.interState,
      );
      // 1180 inclusive of 18% => taxable = 1000, IGST = 180.
      expect(result.taxableValue.toStringAsFixed(2), '1000.00');
      expect(result.igstTotal, Decimal.parse('180'));
      expect(result.grandTotal, Decimal.parse('1180'));
    });

    test('rounds the grand total to the nearest rupee', () {
      final result = GstEngine.computeDocument(
        lines: [
          line(qty: 1, rate: 100.33, gst: 18),
        ],
        split: GstSplit.interState,
      );
      // 100.33 + 18% = 118.3894 -> round to 118.
      expect(result.grandTotal, Decimal.parse('118'));
      expect(result.roundOff, isNot(Decimal.zero));
    });

    test('aggregates the rate-wise split for GSTR-style reports', () {
      final result = GstEngine.computeDocument(
        lines: [
          line(qty: 2, rate: 500, gst: 18),
          line(qty: 1, rate: 200, gst: 12),
          line(qty: 1, rate: 100, gst: 18),
        ],
        split: GstSplit.interState,
      );
      final byRate = {for (final r in result.rateWise) r.rate: r};
      expect(byRate.containsKey(18), isTrue);
      expect(byRate[18]!.taxableValue, Decimal.parse('1100'));
      expect(byRate[18]!.lineCount, 2);
      expect(byRate[12]!.taxableValue, Decimal.parse('200'));
    });
  });

  group('Financial year', () {
    test('starts on 1 April', () {
      expect(FinancialYear.forDate(DateTime(2026, 3, 31)).shortLabel, '2025-26');
      expect(FinancialYear.forDate(DateTime(2026, 4, 1)).shortLabel, '2026-27');
      expect(FinancialYear.forDate(DateTime(2026, 12, 1)).shortLabel, '2026-27');
    });
  });

  group('Number to words (Indian system)', () {
    test('formats lakhs and crores', () {
      expect(NumberToWords.indianCurrency(0),
          'Rupees Zero only');
      expect(NumberToWords.indianCurrency(7), 'Rupees Seven only');
      expect(NumberToWords.indianCurrency(1180),
          'Rupees One Thousand One Hundred Eighty only');
      expect(NumberToWords.indianCurrency(1234567),
          'Rupees Twelve Lakh Thirty Four Thousand Five Hundred Sixty Seven only');
      expect(NumberToWords.indianCurrency(12000000),
          'Rupees One Crore Twenty Lakh only');
    });
  });

  group('State resolution', () {
    test('reads the state code from a GSTIN', () {
      expect(IndianStates.stateCodeFromGstin('29AAACI1681G1ZL'), '29');
      expect(IndianStates.stateCodeFromGstin('27AAGCG4576J1Z6'), '27');
      expect(IndianStates.stateCodeFromGstin(null), isNull);
    });
  });
}
