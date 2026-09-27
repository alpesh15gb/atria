import 'package:atria/core/database/repositories/report_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PartyStatement period totals', () {
    test('totalDebit/totalCredit exclude the Opening Balance carry-forward',
        () {
      final statement = PartyStatement(
        partyId: 'p1',
        partyName: 'Acme',
        opening: Decimal.fromInt(500),
        closing: Decimal.fromInt(1500),
        lines: [
          LedgerLine(
            date: DateTime(2026, 4, 1),
            particulars: 'Opening Balance',
            reference: '',
            debit: Decimal.fromInt(500),
            credit: Decimal.zero,
            balance: Decimal.fromInt(500),
          ),
          LedgerLine(
            date: DateTime(2026, 4, 5),
            particulars: 'Sales Invoice INV/1',
            reference: 'INV/1',
            debit: Decimal.fromInt(1000),
            credit: Decimal.zero,
            balance: Decimal.fromInt(1500),
          ),
          LedgerLine(
            date: DateTime(2026, 4, 9),
            particulars: 'Payment Received PAY/1',
            reference: 'PAY/1',
            debit: Decimal.zero,
            credit: Decimal.zero,
            balance: Decimal.fromInt(1500),
          ),
        ],
      );

      // The opening row is a carry-forward, not period activity — including
      // it would double-count the opening balance in the PDF summary cells.
      expect(statement.totalDebit, Decimal.fromInt(1000));
      expect(statement.totalCredit, Decimal.zero);
    });
  });
}
