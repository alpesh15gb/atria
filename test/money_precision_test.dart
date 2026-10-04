import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/utils/money.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The money-as-`REAL` guard.
///
/// Every money column in the schema is a SQLite `REAL` (a double) while the
/// engine computes in `Decimal`. That is a deliberate, documented decision — see
/// the "Money is stored as a double" note in `.claude/DECISIONS.md` — and it is
/// only safe as long as one rule holds: **a value is rounded to paise before it
/// is written**, and every amount that is summed is read back as it was stored.
///
/// That rule is what this file pins. A double can represent any 2-decimal value
/// whose decimal string is short (0.1 + 0.2 being the famous exception), so the
/// invariant to test is not "the arithmetic is exact" but "nothing sub-paise
/// ever reaches the database, and totals read back to the paisa".
void main() {
  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Shri Balaji Traders',
      stateCode: '29',
    );
    firmId = firm.id;
  });

  tearDown(() => db.close());

  /// True when [value] carries no more than two decimal places.
  ///
  /// Checked on the shortest round-tripping decimal string, which is what Dart
  /// prints and what `Decimal.parse` reads back — the same conversion the
  /// reports use.
  bool isPaiseClean(double value) {
    final text = value.abs().toString();
    if (text.contains('e')) return false; // scientific notation is never clean
    final parts = text.split('.');
    return parts.length == 1 || parts[1].length <= 2;
  }

  test('awkward rates never store a fraction of a paisa', () async {
    // 3 x 99.99 = 299.97 with a 7.5% invoice discount and 18% GST on the net,
    // which is a division that does not terminate: 100/3 of a paisa per line.
    await db.salesRepositoryFor(firmId).save(SalesDraft(
      id: 'awkward',
      number: 'INV-AWK',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 6, 1),
      invoiceDiscountPercent: Decimal.parse('7.5'),
      lines: [
        SalesLineDraft(
          id: 'awk-line',
          name: 'Widget',
          quantity: Decimal.fromInt(3),
          unit: 'pcs',
          rate: Decimal.parse('99.99'),
          gstRate: 18,
        ),
      ],
    ));

    final doc = (await db.salesRepositoryFor(firmId).getById('awkward'))!;
    final moneyColumns = <String, double>{
      'subTotal': doc.subTotal,
      'itemDiscount': doc.itemDiscount,
      'invoiceDiscountAmount': doc.invoiceDiscountAmount,
      'taxableValue': doc.taxableValue,
      'cgst': doc.cgst,
      'sgst': doc.sgst,
      'igst': doc.igst,
      'roundOff': doc.roundOff,
      'grandTotal': doc.grandTotal,
    };
    moneyColumns.forEach((name, value) {
      expect(isPaiseClean(value), isTrue,
          reason: '$name stored $value, which is finer than a paisa');
    });

    // The stored halves still add up to the stored whole, to the paisa. The
    // round-off is part of that sum: the document rounds to the rupee, so
    // tax alone cannot equal the difference.
    expect(doc.cgst + doc.sgst + doc.igst + doc.roundOff,
        closeTo(doc.grandTotal - doc.taxableValue, 0.01));
  });

  test('every line total survives the round trip through REAL', () async {
    await db.salesRepositoryFor(firmId).save(SalesDraft(
      id: 'lines',
      number: 'INV-LINES',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 6, 2),
      lines: [
        for (var i = 0; i < 7; i++)
          SalesLineDraft(
            id: 'line-$i',
            name: 'Widget $i',
            // 1/7 of a rupee per unit is the classic repeating decimal.
            quantity: Decimal.fromInt(7),
            unit: 'pcs',
            rate: Decimal.parse('0.${i + 1}'),
            gstRate: 12,
          ),
      ],
    ));

    final lines = await db.salesRepositoryFor(firmId).itemsFor('lines');
    var storedSum = 0.0;
    var decimalSum = Decimal.zero;
    for (final line in lines) {
      expect(isPaiseClean(line.total), isTrue,
          reason: 'line ${line.id} stored ${line.total}');
      storedSum += line.total;
      decimalSum += Decimal.parse(line.total.toString());
    }
    // Adding seven rounded values in double and in Decimal must agree at paisa
    // level, because each value was rounded before it was stored.
    expect(
      Decimal.parse(storedSum.toStringAsFixed(2)),
      decimalSum.round(scale: 2),
    );
  });

  test('summing a thousand receipts stays exact to the paisa', () async {
    final payments = db.paymentRepositoryFor(firmId);
    for (var i = 0; i < 1000; i++) {
      await payments.create(
        type: 'payment_in',
        number: 'RCP-$i',
        amount: 0.10,
        date: DateTime(2026, 6, 3),
        mode: 'cash',
      );
    }

    final total = await payments.totalForType('payment_in',
        from: DateTime(2026, 6, 1), to: DateTime(2026, 6, 30, 23, 59, 59));
    // 1,000 x 0.10 is the sum a double gets famously wrong (99.99999999999999
    // or 100.00000000000001); rounded to paise it must still be exactly 100.
    expect(Money.round2(Money.of(total)), Decimal.parse('100.00'));

    // And the ledger — which is what a balance sheet or a challan reads — must
    // agree with the document sum rather than drifting away from it.
    final ledger = db.ledgerRepositoryFor(firmId);
    final tb = await ledger.trialBalance(asOf: DateTime(2026, 6, 30));
    final cash = tb.rows
        .where((r) => r.account.code == '1000')
        .first;
    expect(Money.round2(Money.of(cash.closing)), Decimal.parse('100.00'));
    expect(tb.isBalanced, isTrue);
  });

  test('a purchase with TDS rounds the same way on both sides', () async {
    await db.purchaseRepositoryFor(firmId).save(PurchaseDraft(
      id: 'b-tds',
      number: 'BILL-TDS',
      docType: 'bill',
      billDate: DateTime(2026, 6, 4),
      // 2% of 299.97 is 5.9994 — must be stored as a paise amount, and the
      // document total must equal taxable + tax − tds exactly.
      tdsRate: Decimal.parse('2'),
      lines: [
        PurchaseLineDraft(
          id: 'pl-tds',
          name: 'Widget',
          quantity: Decimal.fromInt(3),
          unit: 'pcs',
          rate: Decimal.parse('99.99'),
          gstRate: 18,
        ),
      ],
    ));

    final bill = (await db.purchaseRepositoryFor(firmId).getById('b-tds'))!;
    expect(isPaiseClean(bill.tds), isTrue, reason: 'tds stored ${bill.tds}');
    expect(isPaiseClean(bill.grandTotal), isTrue);
    expect(
      bill.taxableValue + bill.cgst + bill.sgst + bill.igst + bill.roundOff -
          bill.tds,
      closeTo(bill.grandTotal, 0.011),
    );
  });
}
