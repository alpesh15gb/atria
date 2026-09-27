import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Persistence round-trip cover for the five document types a user can create
/// from the UI. The user's complaint was that "nothing works" — these prove the
/// write paths behind each "New" button actually store data and read it back.
void main() {
  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Shri Balaji Traders',
      stateCode: '29', // Karnataka
    );
    firmId = firm.id;
  });

  tearDown(() => db.close());

  test('parties persist and are queryable', () async {
    final parties = db.partyRepositoryFor(firmId);
    final customer = await parties.create(
      name: 'Ramesh Kirana Store',
      type: 'customer',
      gstin: '29AABCB1234L1Z5',
      city: 'Bengaluru',
    );
    // A supplier alongside the customer, since parties.all covers both types.
    await parties.create(
      name: 'Mahalaxmi Distributors',
      type: 'supplier',
      city: 'Mysuru',
    );

    expect(await parties.getById(customer.id), isNotNull);
    expect((await parties.getById(customer.id))!.gstin, '29AABCB1234L1Z5');
    final all = await parties.all();
    expect(all.length, 2);
    expect(all.map((p) => p.name).toList(),
        containsAll(['Ramesh Kirana Store', 'Mahalaxmi Distributors']));
  });

  test('items persist with pricing and GST metadata', () async {
    final items = db.itemRepositoryFor(firmId);
    final item = await items.create(
      name: 'Surf Excel 1kg',
      sku: 'SURF-1KG',
      hsn: '3402',
      unit: 'pcs',
      salePrice: 180,
      purchasePrice: 150,
      gstRate: 18,
      openingStock: 40,
      lowStockAlert: 10,
    );

    final read = await items.getById(item.id);
    expect(read, isNotNull);
    expect(read!.name, 'Surf Excel 1kg');
    expect(read.sku, 'SURF-1KG');
    expect(read.hsn, '3402');
    expect(read.salePrice, 180);
    expect(read.gstRate, 18);
    expect(read.openingStock, 40);
  });

  test('a sales invoice persists with the correct GST split and stock effect',
      () async {
    final items = db.itemRepositoryFor(firmId);
    final parties = db.partyRepositoryFor(firmId);
    final sales = db.salesRepositoryFor(firmId);
    final item = await items.create(
      name: 'Surf Excel 1kg',
      salePrice: 1000,
      gstRate: 18,
      openingStock: 20,
    );
    final party = await parties.create(name: 'Ramesh Kirana Store');

    final saved = await sales.save(SalesDraft(
      id: 'inv-1',
      number: 'INV-1',
      docType: 'invoice',
      partyId: party.id,
      invoiceDate: DateTime(2026, 9, 1),
      status: 'confirmed',
      partyName: party.name,
      placeOfSupply: '29',
      isInterState: false, // intra-state => CGST + SGST
      lines: [
        SalesLineDraft(
          id: 'l1',
          itemId: item.id,
          name: item.name,
          hsn: item.hsn,
          quantity: Decimal.fromInt(2),
          unit: 'pcs',
          rate: Decimal.fromInt(1000),
          gstRate: 18,
        ),
      ],
    ));

    // 2 x 1000 = 2000 taxable, 180 CGST + 180 SGST = 2360 total.
    expect(saved.cgst, closeTo(180, 0.01));
    expect(saved.sgst, closeTo(180, 0.01));
    expect(saved.igst, 0);
    expect(saved.grandTotal, closeTo(2360, 0.01));
    expect(saved.balanceDue, closeTo(2360, 0.01));
    expect(saved.paymentStatus, 'unpaid');

    // Stock should have dropped by the billed quantity.
    final after = await items.getById(item.id);
    expect(after!.currentStock, closeTo(18, 0.001));

    // And the invoice should be retrievable the way the list screen reads it.
    final list = await sales.list();
    expect(list.any((i) => i.id == 'inv-1'), isTrue);
  });

  test('an inter-state invoice charges IGST instead of CGST/SGST', () async {
    final parties = db.partyRepositoryFor(firmId);
    final sales = db.salesRepositoryFor(firmId);
    final party = await parties.create(name: 'Delhi Mart', stateCode: '07');

    final saved = await sales.save(SalesDraft(
      id: 'inv-2',
      number: 'INV-2',
      docType: 'invoice',
      partyId: party.id,
      invoiceDate: DateTime(2026, 9, 1),
      partyName: party.name,
      placeOfSupply: '07',
      isInterState: true,
      lines: [
        SalesLineDraft(
          id: 'l1',
          name: 'Consulting',
          quantity: Decimal.fromInt(1),
          unit: 'nos',
          rate: Decimal.fromInt(1000),
          gstRate: 18,
        ),
      ],
    ));

    expect(saved.igst, closeTo(180, 0.01));
    expect(saved.cgst, 0);
    expect(saved.sgst, 0);
  });

  test('a purchase bill persists and adds to stock', () async {
    final items = db.itemRepositoryFor(firmId);
    final purchase = db.purchaseRepositoryFor(firmId);
    final item = await items.create(
      name: 'Surf Excel 1kg',
      salePrice: 180,
      purchasePrice: 150,
      gstRate: 18,
      openingStock: 0,
    );

    final saved = await purchase.save(PurchaseDraft(
      id: 'bill-1',
      number: 'PUR-1',
      docType: 'bill',
      billDate: DateTime(2026, 9, 2),
      status: 'confirmed',
      lines: [
        PurchaseLineDraft(
          id: 'pl1',
          itemId: item.id,
          name: item.name,
          quantity: Decimal.fromInt(10),
          unit: 'pcs',
          rate: Decimal.fromInt(150),
          gstRate: 18,
        ),
      ],
    ));

    expect(saved.grandTotal, closeTo(1770, 0.01));
    final after = await items.getById(item.id);
    expect(after!.currentStock, closeTo(10, 0.001));
  });

  test('expenses persist and appear in the expense list', () async {
    final expenses = db.expenseRepositoryFor(firmId);
    final e = await expenses.create(
      type: 'expense',
      number: 'EXP-1',
      category: 'Rent',
      amount: 15000,
      date: DateTime(2026, 9, 1),
      mode: 'bank',
      notes: 'Shop rent for September',
    );

    expect(e.amount, 15000);
    final all = await expenses.list();
    expect(all.any((x) => x.id == e.id), isTrue);
    expect(all.firstWhere((x) => x.id == e.id).category, 'Rent');
  });
}
