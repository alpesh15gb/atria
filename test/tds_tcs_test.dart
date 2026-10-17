import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// TDS and TCS are the two halves of "tax at source", and both had columns in
/// the schema with *nothing* reading or writing them: a shop could not deduct a
/// 194Q TDS on a purchase or collect a 206C(1H) TCS on a sale, and no report
/// could have known either happened.
///
/// The arithmetic is the part worth pinning: both are charged on the **taxable
/// value**, not the grand total. Getting that wrong over-deducts by the GST on
/// every single document, which is exactly the kind of quiet error that only
/// shows up in a notice months later.
void main() {
  late AppDatabase db;
  late String firmId;
  late SalesRepository sales;
  late PurchaseRepository purchases;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(gstin: '29ABCDE1234F1Z5', 
      name: 'Shri Balaji Traders',
      stateCode: '29',
    );
    firmId = firm.id;
    sales = db.salesRepositoryFor(firmId);
    purchases = db.purchaseRepositoryFor(firmId);
  });

  tearDown(() => db.close());

  Future<void> saveInvoice({Decimal? tcsRate}) async {
    await sales.save(SalesDraft(
      id: 'inv-1',
      number: 'INV-1',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 9, 1),
      status: 'confirmed',
      lines: [
        SalesLineDraft(
          id: 'l1',
          name: 'Cement bag',
          quantity: Decimal.fromInt(1),
          unit: 'bag',
          rate: Decimal.fromInt(10000),
          gstRate: 18,
        ),
      ],
      tcsRate: tcsRate,
    ));
  }

  Future<void> saveBill({Decimal? tdsRate}) async {
    await purchases.save(PurchaseDraft(
      id: 'bill-1',
      number: 'PUR-1',
      docType: 'bill',
      billDate: DateTime(2026, 9, 1),
      status: 'confirmed',
      lines: [
        PurchaseLineDraft(
          id: 'l1',
          name: 'Cement bag',
          quantity: Decimal.fromInt(1),
          unit: 'bag',
          rate: Decimal.fromInt(10000),
          gstRate: 18,
        ),
      ],
      tdsRate: tdsRate,
    ));
  }

  test('TCS is collected on the taxable value and joins the total', () async {
    await saveInvoice(tcsRate: Decimal.parse('0.1'));

    final invoice = (await sales.getById('inv-1'))!;
    expect(invoice.taxableValue, 10000);
    // 0.1% of 10,000, not of 11,800: the GST is not part of the consideration.
    expect(invoice.tcs, closeTo(10, 0.001));
    expect(invoice.tcsRate, closeTo(0.1, 0.0001));
    expect(invoice.grandTotal, closeTo(11810, 0.001));
  });

  test('TDS is deducted on the taxable value and comes off the total',
      () async {
    await saveBill(tdsRate: Decimal.parse('0.1'));

    final bill = (await purchases.getById('bill-1'))!;
    expect(bill.taxableValue, 10000);
    expect(bill.tds, closeTo(10, 0.001));
    expect(bill.tdsRate, closeTo(0.1, 0.0001));
    expect(bill.grandTotal, closeTo(11790, 0.001));
  });

  test('no rate means no tax at source, and the totals are untouched',
      () async {
    await saveInvoice();
    await saveBill();

    final invoice = (await sales.getById('inv-1'))!;
    expect(invoice.tcs, 0);
    expect(invoice.tcsRate, 0);
    expect(invoice.grandTotal, closeTo(11800, 0.001));

    final bill = (await purchases.getById('bill-1'))!;
    expect(bill.tds, 0);
    expect(bill.grandTotal, closeTo(11800, 0.001));
  });

  test('a payment of the TCS-inclusive total settles the invoice', () async {
    await saveInvoice(tcsRate: Decimal.parse('0.1'));
    final invoice = (await sales.getById('inv-1'))!;

    final payments = db.paymentRepositoryFor(firmId);
    await payments.create(
      type: 'payment_in',
      number: 'RCPT-1',
      partyId: invoice.partyId,
      amount: invoice.grandTotal,
      date: DateTime(2026, 9, 2),
      linkedInvoiceId: invoice.id,
    );
    // The same settle path the payments screen uses: the TCS-inclusive grand
    // total is what the balance is derived from.
    await sales.applyPayment(
      invoiceId: invoice.id,
      amount: invoice.grandTotal,
      date: DateTime(2026, 9, 2),
    );

    final settled = (await sales.getById('inv-1'))!;
    expect(settled.paymentStatus, 'paid');
    expect(settled.balanceDue, closeTo(0, 0.001));
  });

  test('the report totals what was deducted and collected', () async {
    await saveInvoice(tcsRate: Decimal.parse('0.1'));
    await saveBill(tdsRate: Decimal.parse('1'));

    final summary = await db.reportRepositoryFor(firmId).taxAtSource(
      from: DateTime(2026, 9, 1),
      to: DateTime(2026, 9, 30),
    );

    expect(summary.tcsCollected.toDouble(), closeTo(10, 0.001));
    expect(summary.tdsDeducted.toDouble(), closeTo(100, 0.001));
    expect(summary.total.toDouble(), closeTo(110, 0.001));
    expect(summary.invoicesWithTcs, 1);
    expect(summary.billsWithTds, 1);
    // And it reads the documents' own totals, so a period with none is empty
    // rather than a zeroed card full of rows.
    final empty = await db.reportRepositoryFor(firmId).taxAtSource(
      from: DateTime(2026, 10, 1),
      to: DateTime(2026, 10, 31),
    );
    expect(empty.isEmpty, true);
  });

  test('an edit that removes the rate puts the total back', () async {
    await saveInvoice(tcsRate: Decimal.parse('5'));
    // 5% of the 10,000 taxable value, on top of the 11,800 the goods cost.
    expect((await sales.getById('inv-1'))!.grandTotal, closeTo(12300, 0.001));

    await saveInvoice();
    final invoice = (await sales.getById('inv-1'))!;
    expect(invoice.tcs, 0);
    expect(invoice.grandTotal, closeTo(11800, 0.001));
  });
}
