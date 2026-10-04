import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cover for the profit & loss account.
///
/// The report used to treat every purchase as a cost of the period it was
/// bought in, which is only right for a business with nothing left on the
/// shelf: a shop that bought ₹1,00,000 of goods in March and sold ₹20,000 of
/// them showed an ₹80,000 loss on goods it still owned. Opening and closing
/// stock are what turn purchases into cost of goods *sold*.
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

  Future<String> stockItem({double cost = 100, double price = 200}) async {
    final item = await db.itemRepositoryFor(firmId).create(
          name: 'Surf Excel 1kg',
          salePrice: price,
          purchasePrice: cost,
          gstRate: 0,
          stockType: 'tracked',
        );
    return item.id;
  }

  Future<void> buy(String itemId, double quantity, double rate, DateTime date,
      {String number = 'BILL-1'}) async {
    await db.purchaseRepositoryFor(firmId).save(PurchaseDraft(
      id: 'bill-$number',
      number: number,
      docType: 'bill',
      billDate: date,
      lines: [
        PurchaseLineDraft(
          id: 'pl-$number',
          itemId: itemId,
          name: 'Surf Excel 1kg',
          quantity: Decimal.parse('$quantity'),
          unit: 'pcs',
          rate: Decimal.parse('$rate'),
          gstRate: 0,
        ),
      ],
    ));
  }

  Future<void> sell(String itemId, double quantity, double rate, DateTime date,
      {String number = 'INV-1'}) async {
    await db.salesRepositoryFor(firmId).save(SalesDraft(
      id: 'invoice-$number',
      number: number,
      docType: 'invoice',
      invoiceDate: date,
      lines: [
        SalesLineDraft(
          id: 'sl-$number',
          itemId: itemId,
          name: 'Surf Excel 1kg',
          quantity: Decimal.parse('$quantity'),
          unit: 'pcs',
          rate: Decimal.parse('$rate'),
          gstRate: 0,
        ),
      ],
    ));
  }

  test('a business with no stock behaves exactly as before', () async {
    await db.salesRepositoryFor(firmId).save(SalesDraft(
      id: 'service-invoice',
      number: 'INV-1',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 6, 10),
      lines: [
        SalesLineDraft(
          id: 'sl',
          name: 'Consulting',
          quantity: Decimal.one,
          unit: 'hrs',
          rate: Decimal.parse('5000'),
          gstRate: 18,
        ),
      ],
    ));
    await db.expenseRepositoryFor(firmId).create(
          type: 'expense',
          number: 'EXP-1',
          category: 'rent',
          amount: 1200,
          date: DateTime(2026, 6, 12),
          mode: 'bank_transfer',
        );

    final pnl = await db.reportRepositoryFor(firmId).profitAndLoss(
          from: DateTime(2026, 6, 1),
          to: DateTime(2026, 6, 30, 23, 59, 59),
        );
    expect(pnl.hasStockAdjustment, isFalse);
    expect(pnl.grossProfit, Decimal.parse('5000.00'));
    expect(pnl.netProfit, Decimal.parse('3800.00'));
    expect(pnl.totalExpenses, Decimal.parse('1200.00'));
  });

  test('stock bought and not sold is an asset, not a cost', () async {
    final itemId = await stockItem(cost: 100);
    await buy(itemId, 100, 100, DateTime(2026, 6, 5));
    await sell(itemId, 10, 200, DateTime(2026, 6, 20));

    final pnl = await db.reportRepositoryFor(firmId).profitAndLoss(
          from: DateTime(2026, 6, 1),
          to: DateTime(2026, 6, 30, 23, 59, 59),
        );

    // Sales 2,000; goods purchased 10,000; closing stock 9,000 at cost.
    expect(pnl.hasStockAdjustment, isTrue);
    expect(pnl.openingStock, Decimal.parse('0.00'));
    expect(pnl.closingStock, Decimal.parse('9000.00'));
    expect(pnl.costOfGoodsSold, Decimal.parse('1000.00'));
    expect(pnl.grossProfit, Decimal.parse('1000.00'));
    expect(pnl.netProfit, Decimal.parse('1000.00'));
    // The trading account still lists what was purchased, so the working is
    // visible rather than silently netted off.
    expect(
      pnl.expenseRows.first.amount,
      Decimal.parse('10000.00'),
      reason: 'the purchase line stays visible above the adjustment',
    );
  });

  test('closing stock becomes the next period\'s opening stock', () async {
    final itemId = await stockItem(cost: 100);
    await buy(itemId, 100, 100, DateTime(2026, 6, 5));
    await sell(itemId, 10, 200, DateTime(2026, 6, 20));
    await sell(itemId, 40, 200, DateTime(2026, 7, 10), number: 'INV-2');

    final repo = db.reportRepositoryFor(firmId);
    final july = await repo.profitAndLoss(
      from: DateTime(2026, 7, 1),
      to: DateTime(2026, 7, 31, 23, 59, 59),
    );
    expect(july.openingStock, Decimal.parse('9000.00'));
    expect(july.closingStock, Decimal.parse('5000.00'));
    // 40 sold at 200 = 8,000, against 4,000 of stock consumed.
    expect(july.costOfGoodsSold, Decimal.parse('4000.00'));
    expect(july.grossProfit, Decimal.parse('4000.00'));

    // The two periods' stock valuations meet in the middle: whatever June
    // called closing stock, July calls opening stock.
    final june = await repo.profitAndLoss(
      from: DateTime(2026, 6, 1),
      to: DateTime(2026, 6, 30, 23, 59, 59),
    );
    expect(june.closingStock, july.openingStock);
  });

  test('opening stock is carried in from before the period', () async {
    final itemId = await stockItem(cost: 50);
    await buy(itemId, 20, 50, DateTime(2026, 5, 1));
    await sell(itemId, 5, 90, DateTime(2026, 6, 15));

    final pnl = await db.reportRepositoryFor(firmId).profitAndLoss(
          from: DateTime(2026, 6, 1),
          to: DateTime(2026, 6, 30, 23, 59, 59),
        );
    expect(pnl.openingStock, Decimal.parse('1000.00'));
    expect(pnl.closingStock, Decimal.parse('750.00'));
    expect(pnl.costOfGoodsSold, Decimal.parse('250.00'));
    expect(pnl.grossProfit, Decimal.parse('200.00'));
  });

  test('stock on hand can be valued at any date', () async {
    final itemId = await stockItem(cost: 25);
    await buy(itemId, 40, 25, DateTime(2026, 6, 5));
    await sell(itemId, 10, 40, DateTime(2026, 6, 20));
    final repo = db.reportRepositoryFor(firmId);

    expect(await repo.stockAtCost(asOf: DateTime(2026, 6, 4)),
        0); // before the purchase
    expect(await repo.stockAtCost(asOf: DateTime(2026, 6, 5)), 1000);
    expect(await repo.stockAtCost(asOf: DateTime(2026, 6, 20)), 750);
  });

  test('billing ahead of the purchase does not invent a negative asset',
      () async {
    final itemId = await stockItem(cost: 100);
    await sell(itemId, 5, 200, DateTime(2026, 6, 10));

    final pnl = await db.reportRepositoryFor(firmId).profitAndLoss(
          from: DateTime(2026, 6, 1),
          to: DateTime(2026, 6, 30, 23, 59, 59),
        );
    // Stock is negative at the ledger layer; it is not an asset, and valuing
    // it would have reported a profit larger than the sale.
    expect(pnl.closingStock, Decimal.parse('0.00'));
    expect(pnl.costOfGoodsSold, Decimal.parse('0.00'));
    expect(pnl.grossProfit, Decimal.parse('1000.00'));
  });
}
