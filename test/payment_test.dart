import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/utils/formatters.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cover for the payment-recording path.
///
/// `applyPayment` clamps `balanceDue` at zero but keeps the full amount in
/// `paidAmount`, so a ₹12,000 payment against a ₹10,000 invoice silently
/// swallowed the ₹2,000 excess: the invoice read "paid" and the customer's
/// change was nowhere. The detail screen now caps the recorded amount at the
/// balance due, so this test pins both the repository contract it relies on
/// and the money format the cap message shows.
void main() {
  late AppDatabase db;
  late String firmId;
  late SalesRepository sales;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Shri Balaji Traders',
      stateCode: '29',
    );
    firmId = firm.id;
    sales = db.salesRepositoryFor(firmId);
  });

  tearDown(() => db.close());

  Future<void> createInvoice() async {
    final item = await db.itemRepositoryFor(firmId).create(
      name: 'Surf Excel 1kg',
      salePrice: 10000,
      gstRate: 0,
    );
    await sales.save(SalesDraft(
      id: 'inv-1',
      number: 'INV-1',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 9, 1),
      status: 'confirmed',
      lines: [
        SalesLineDraft(
          id: 'l1',
          itemId: item.id,
          name: item.name,
          quantity: Decimal.fromInt(1),
          unit: 'pcs',
          rate: Decimal.fromInt(10000),
          gstRate: 0,
        ),
      ],
    ));
  }

  test('a full payment marks the invoice paid', () async {
    await createInvoice();
    await sales.applyPayment(invoiceId: 'inv-1', amount: 10000);

    final doc = await sales.getById('inv-1');
    expect(doc!.paymentStatus, 'paid');
    expect(doc.balanceDue, 0);
  });

  test('a partial payment leaves a balance and the partial status', () async {
    await createInvoice();
    await sales.applyPayment(invoiceId: 'inv-1', amount: 4000);

    final doc = await sales.getById('inv-1');
    expect(doc!.paymentStatus, 'partial');
    expect(doc.paidAmount, 4000);
    expect(doc.balanceDue, 6000);
  });

  test('a payment larger than the balance still closes the invoice', () async {
    // The repository clamps the balance at zero; the screen is what caps the
    // amount. Pin the clamp so it cannot start carrying negative balances.
    await createInvoice();
    await sales.applyPayment(invoiceId: 'inv-1', amount: 12000);

    final doc = await sales.getById('inv-1');
    expect(doc!.paymentStatus, 'paid');
    expect(doc.balanceDue, 0,
        reason: 'The balance must never go negative. The excess is handled by '
            'the detail screen, which caps the recorded amount and tells the '
            'user what it actually recorded.');
  });

  test('the cap message renders Indian-grouped money', () {
    // The cap reads this value back to the user.
    expect(Formatters.money(Decimal.fromInt(10000)), '₹10,000.00');
    expect(Formatters.money(Decimal.parse('1250.5')), '₹1,250.50');
  });
}
