import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/engine/gst_engine.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards for the document *edit* paths. Both repositories used to run the
/// same INSERT on save regardless of whether the id already existed:
/// - purchase: editing a bill threw `UNIQUE constraint failed`, because the
///   bill row and every line row were plain-INSERTed with persisted ids;
/// - sales: the editor side-stepped the throw by marking the old invoice
///   cancelled and saving under a fresh id, but markCancelled never reversed
///   stock, so an edit deducted the quantity twice, and any payment already
///   recorded was orphaned against the dead id;
/// - both also reset paidAmount to 0 and overwrote createdAt.
void main() {
  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(gstin: '29ABCDE1234F1Z5', 
      name: 'Shri Balaji Traders',
      stateCode: '29',
    );
    firmId = firm.id;
  });

  tearDown(() => db.close());

  test('editing a sales invoice deducts the new quantity, not both', () async {
    final items = db.itemRepositoryFor(firmId);
    final sales = db.salesRepositoryFor(firmId);
    final item = await items.create(
      name: 'Surf Excel 1kg',
      salePrice: 1000,
      gstRate: 18,
      openingStock: 20,
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
          quantity: Decimal.fromInt(2),
          unit: 'pcs',
          rate: Decimal.fromInt(1000),
          gstRate: 18,
        ),
      ],
    ));
    expect((await items.getById(item.id))!.currentStock, 18);

    final edited = await sales.save(SalesDraft(
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
          quantity: Decimal.fromInt(5),
          unit: 'pcs',
          rate: Decimal.fromInt(1000),
          gstRate: 18,
        ),
      ],
    ));

    // 20 - 5, not 20 - 2 - 5.
    expect((await items.getById(item.id))!.currentStock, 15);
    expect(edited.grandTotal, closeTo(5900, 0.01));

    // One row in the list, not the original plus a leftover copy.
    expect((await sales.list()).where((d) => d.id == 'inv-1').length, 1);
    // Lines were replaced rather than appended.
    expect((await sales.itemsFor('inv-1')).length, 1);
    expect((await sales.itemsFor('inv-1')).first.quantity, 5);
    // The stock ledger shows a reversal for every duplicate posting.
    // (The item's `opening` movement is excluded — it isn't ours to undo.)
    // The ledger is append-only: the edit posts a reversal row, then the new
    // sale row. Before the fix there was no reversal, so the net was -7.
    final movements = (await (db.select(db.stockMovements)
              ..where((t) => t.itemId.equals(item.id)))
            .get())
        .where((m) => m.sourceId == 'inv-1')
        .toList();
    expect(movements.map((m) => m.quantity).toList(), [-2, 2, -5]);
    expect(movements.map((m) => m.quantity).fold<double>(0, (a, b) => a + b),
        -5);
  });

  test('an invoice edit keeps payments and derives its balances from them',
      () async {
    final sales = db.salesRepositoryFor(firmId);
    await sales.save(SalesDraft(
      id: 'inv-2',
      number: 'INV-2',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 9, 1),
      status: 'confirmed',
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
    await sales.applyPayment(invoiceId: 'inv-2', amount: 600);

    final edited = await sales.save(SalesDraft(
      id: 'inv-2',
      number: 'INV-2',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 9, 1),
      status: 'confirmed',
      lines: [
        SalesLineDraft(
          id: 'l1',
          name: 'Consulting',
          quantity: Decimal.fromInt(2),
          unit: 'nos',
          rate: Decimal.fromInt(1000),
          gstRate: 18,
        ),
      ],
    ));

    expect(edited.paidAmount, 600);
    expect(edited.grandTotal, closeTo(2360, 0.01));
    expect(edited.balanceDue, closeTo(1760, 0.01));
    expect(edited.paymentStatus, 'partial');
  });

  test('editing a purchase bill rewrites it instead of throwing', () async {
    final items = db.itemRepositoryFor(firmId);
    final purchase = db.purchaseRepositoryFor(firmId);
    final item = await items.create(
      name: 'Surf Excel 1kg',
      purchasePrice: 150,
      gstRate: 18,
      openingStock: 0,
    );

    await purchase.save(PurchaseDraft(
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
    expect((await items.getById(item.id))!.currentStock, 10);

    final edited = await purchase.save(PurchaseDraft(
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
          quantity: Decimal.fromInt(4),
          unit: 'pcs',
          rate: Decimal.fromInt(150),
          gstRate: 18,
        ),
      ],
    ));

    expect(edited.grandTotal, closeTo(708, 0.01));
    expect((await items.getById(item.id))!.currentStock, 4);
    expect((await purchase.list()).where((d) => d.id == 'bill-1').length, 1);
    expect((await purchase.itemsFor('bill-1')).length, 1);
  });

  test('a bill edit keeps the payments already recorded against it',
      () async {
    final purchase = db.purchaseRepositoryFor(firmId);
    await purchase.save(PurchaseDraft(
      id: 'bill-2',
      number: 'PUR-2',
      docType: 'bill',
      billDate: DateTime(2026, 9, 2),
      status: 'confirmed',
      lines: [
        PurchaseLineDraft(
          id: 'pl1',
          name: 'Rent',
          quantity: Decimal.fromInt(1),
          unit: 'nos',
          rate: Decimal.fromInt(1000),
          gstRate: 0,
        ),
      ],
    ));
    await purchase.applyPayment(billId: 'bill-2', amount: 1000);

    final edited = await purchase.save(PurchaseDraft(
      id: 'bill-2',
      number: 'PUR-2',
      docType: 'bill',
      billDate: DateTime(2026, 9, 2),
      status: 'confirmed',
      lines: [
        PurchaseLineDraft(
          id: 'pl1',
          name: 'Rent',
          quantity: Decimal.fromInt(1),
          unit: 'nos',
          rate: Decimal.fromInt(1500),
          gstRate: 0,
        ),
      ],
    ));

    expect(edited.paidAmount, 1000);
    expect(edited.grandTotal, 1500);
    expect(edited.balanceDue, 500);
    expect(edited.paymentStatus, 'partial');
  });

  test('a percent invoice discount is readable from the stored totals', () async {
    // The engine's resolved discount was never persisted — only its inputs
    // were — so a 10% discount showed as ₹0.00 on the PDF and detail card
    // while the totals were already reduced.
    final sales = db.salesRepositoryFor(firmId);
    await sales.save(SalesDraft(
      id: 'inv-3',
      number: 'INV-3',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 9, 3),
      status: 'confirmed',
      invoiceDiscountPercent: Decimal.fromInt(10),
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

    final doc = await sales.getById('inv-3');
    expect(doc, isNotNull);
    expect(
        GstEngine.resolvedInvoiceDiscount(
          subTotal: doc!.subTotal,
          itemDiscount: doc.itemDiscount,
          invoiceDiscountPercent: doc.invoiceDiscountPercent,
          invoiceDiscountAmount: doc.invoiceDiscountAmount,
        ),
        closeTo(100, 0.01));

    // And no discount at all resolves to exactly zero (no rounding noise).
    await sales.save(SalesDraft(
      id: 'inv-4',
      number: 'INV-4',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 9, 3),
      status: 'confirmed',
      lines: [
        SalesLineDraft(
          // Line ids are globally unique (the table's PK is just `id`).
          id: 'l4-1',
          name: 'Consulting',
          quantity: Decimal.fromInt(3),
          unit: 'nos',
          rate: Decimal.fromInt(333),
          gstRate: 18,
        ),
      ],
    ));
    final plain = await sales.getById('inv-4');
    expect(
        GstEngine.resolvedInvoiceDiscount(
          subTotal: plain!.subTotal,
          itemDiscount: plain.itemDiscount,
          invoiceDiscountPercent: plain.invoiceDiscountPercent,
          invoiceDiscountAmount: plain.invoiceDiscountAmount,
        ),
        0);
  });

  test('saved lines carry their own resolved tax, not zeros', () async {
    final items = db.itemRepositoryFor(firmId);
    final purchase = db.purchaseRepositoryFor(firmId);
    final item = await items.create(
      name: 'Surf Excel 1kg',
      purchasePrice: 1000,
      gstRate: 18,
      openingStock: 0,
    );

    await purchase.save(PurchaseDraft(
      id: 'bill-3',
      number: 'PUR-3',
      docType: 'bill',
      billDate: DateTime(2026, 9, 3),
      status: 'confirmed',
      lines: [
        PurchaseLineDraft(
          id: 'pl1',
          itemId: item.id,
          name: item.name,
          quantity: Decimal.fromInt(2),
          unit: 'pcs',
          rate: Decimal.fromInt(1000),
          gstRate: 18,
        ),
      ],
    ));

    final line = (await purchase.itemsFor('bill-3')).single;
    // The line table columns are what the detail view and PDF render; before
    // the fix they were left at their DEFAULT 0.
    expect(line.taxableValue, closeTo(2000, 0.01));
    expect(line.cgst, closeTo(180, 0.01));
    expect(line.sgst, closeTo(180, 0.01));
    expect(line.igst, 0);
    expect(line.total, closeTo(2360, 0.01));
  });
}
