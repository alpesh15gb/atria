import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/item_repository.dart';
import 'package:atria/core/database/repositories/party_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/engine/gst_engine.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/sources/item_stock/item_common.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The eleven Item/Stock reports.
///
/// **The assertions here are about costing, not about rendering.** A stock
/// report that draws is easy; one that values stock at today's purchase price, or
/// that files a returned bag as still on the shelf, is the thing that makes a
/// CA disbelieve the whole book. So the fixtures are built so that the wrong
/// answer is a *different number* rather than a missing row — a purchase in one
/// month, a sale in another, a credit note and a debit note against the same
/// item.
void main() {
  late AppDatabase db;
  late String firmId;
  late ItemRepository items;
  late SalesRepository sales;
  late PurchaseRepository purchases;
  late PartyRepository parties;
  late String itemId;
  late String cheapId;

  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(gstin: '29ABCDE1234F1Z5', 
      name: 'Apex Traders',
      stateCode: '29',
    );
    firmId = firm.id;
    items = db.itemRepositoryFor(firmId);
    sales = db.salesRepositoryFor(firmId);
    purchases = db.purchaseRepositoryFor(firmId);
    parties = db.partyRepositoryFor(firmId);

    final cement = await items.create(
      name: 'Cement bag',
      hsn: '2523',
      purchasePrice: 800,
      salePrice: 1000,
      gstRate: 18,
      lowStockAlert: 3,
    );
    itemId = cement.id;

    // A second item that is only ever bought, so "the union of both sides" is
    // testable: an Item Wise P&L that iterates the sales map alone drops it.
    final bricks = await items.create(
      name: 'Bricks',
      hsn: '4421',
      purchasePrice: 5,
      salePrice: 9,
      gstRate: 5,
    );
    cheapId = bricks.id;
  });

  tearDown(() => db.close());

  Future<String> category(String name) =>
      items.createCategory(name, kind: 'item').then((c) => c.id);

  /// The stored item row.
  ///
  /// `ItemRepository` is a write-only façade — create, update, delete — so a
  /// fixture that needs to read a master back goes to the table. Going through
  /// `db` also means the assertions below are about what is *stored*, which is
  /// what the reports read.
  Future<ItemEntity> storedItem(String id) =>
      (db.select(db.items)..where((i) => i.id.equals(id))).getSingle();

  Future<void> put(ItemEntity item) => items.update(item);

  /// Change one field on a stored item.
  ///
  /// Spelled this way rather than `put((await storedItem(id)).copyWith(…))` at
  /// every call site, because that shape has two `await`s in it and only one of
  /// them is on a Future — which the analyzer rightly complains about every
  /// time.
  Future<void> patchItem(
    String id,
    ItemEntity Function(ItemEntity) change,
  ) async => put(change(await storedItem(id)));

  Future<String> party(String name) async =>
      (await parties.create(name: name, type: 'both')).id;

  /// An invoice of [quantity] at [rate], before tax.
  Future<void> invoice({
    required String id,
    required DateTime date,
    required String partyId,
    String? item,
    String quantity = '1',
    String rate = '1000',
    String docType = 'invoice',
    String name = 'Cement bag',
    String? discount,
    Decimal? invoiceDiscountAmount,
    double gstRate = 18,
    TaxMode taxMode = TaxMode.exclusive,
  }) async {
    await sales.save(
      SalesDraft(
        id: id,
        number: id.toUpperCase(),
        invoiceDate: date,
        docType: docType,
        partyId: partyId,
        partyName: 'Customer',
        invoiceDiscountAmount: invoiceDiscountAmount,
        lines: [
          SalesLineDraft(
            id: '$id-l1',
            itemId: item ?? itemId,
            name: name,
            hsn: '2523',
            quantity: Decimal.parse(quantity),
            unit: 'bag',
            rate: Decimal.parse(rate),
            discountAmount: discount == null ? null : Decimal.parse(discount),
            gstRate: gstRate,
            taxMode: taxMode,
          ),
        ],
      ),
    );
  }

  Future<void> bill({
    required String id,
    required DateTime date,
    required String partyId,
    String? item,
    String quantity = '1',
    String rate = '800',
    String docType = 'bill',
    String name = 'Cement bag',
  }) async {
    await purchases.save(
      PurchaseDraft(
        id: id,
        number: id.toUpperCase(),
        billDate: date,
        docType: docType,
        partyId: partyId,
        partyName: 'Supplier',
        lines: [
          PurchaseLineDraft(
            id: '$id-l1',
            itemId: item ?? itemId,
            name: name,
            hsn: '2523',
            quantity: Decimal.parse(quantity),
            unit: 'bag',
            rate: Decimal.parse(rate),
            gstRate: 18,
          ),
        ],
      ),
    );
  }

  Future<ReportResult> run(
    String id, {
    Map<String, Object?> filters = const {},
    ReportWindow? over,
  }) async {
    final definition = ReportCatalogue.byId(id);
    expect(definition, isNotNull, reason: 'no report registered as "$id"');
    return definition!.run(db, firmId, over ?? window, filters: filters);
  }

  /// The single row a one-item report should have produced.
  ReportRow only(ReportResult result) {
    expect(result.rows, hasLength(1), reason: 'expected one row');
    return result.rows.single;
  }

  group('movementsByItem', () {
    test('a sale leaves and a sale return comes back', () async {
      // `sales_repository` writes a sale as a **negative** quantity and a credit
      // note as a **positive** one. A reader who assumes the opposite files the
      // returned bag as an outbound movement, which leaves it on the shelf and
      // counts the sale as never having happened.
      final customer = await party('Beti Foods');
      final supplier = await party('BuildMart');
      await invoice(id: 'i1', date: DateTime(2026, 4, 10), partyId: customer);
      await invoice(
        id: 'i2',
        date: DateTime(2026, 5, 10),
        partyId: customer,
        docType: 'credit_note',
      );
      await bill(id: 'b1', date: DateTime(2026, 4, 1), partyId: supplier);

      final m = (await movementsByItem(db, firmId, window))[itemId]!;

      // Sold and returned are **separate columns, not one netted figure**. A
      // report that showed only the net would hide a returned item behind a sale
      // that never happened; showing only the gross would overstate both the
      // quantity and the margin. Net is the reader's subtraction.
      expect(m.saleQty, Decimal.fromInt(1), reason: 'one sold');
      expect(m.saleReturnQty, Decimal.fromInt(1), reason: 'one given back');
      // And the return puts stock *back*, so it is inbound rather than another
      // outbound — which is what makes `inbound - outbound` agree with the
      // change in `items.currentStock`. Two came in: the purchase and the
      // returned bag. One went out: the sale.
      expect(m.inboundQty, Decimal.fromInt(2));
      expect(m.outboundQty, Decimal.fromInt(1));

      // A credit note's value is the cost the goods left at, not the sale
      // price: stock goes back at what it was worth on the shelf, and valuing
      // it at the invoice rate would hand the firm free margin.
      expect(m.saleReturnValue, Decimal.fromInt(800));
    });

    test('a purchase return is outbound, not another purchase', () async {
      final supplier = await party('BuildMart');
      await bill(id: 'b1', date: DateTime(2026, 4, 1), partyId: supplier);
      await bill(
        id: 'b2',
        date: DateTime(2026, 5, 1),
        partyId: supplier,
        docType: 'debit_note',
        quantity: '5',
      );

      final m = (await movementsByItem(db, firmId, window))[itemId]!;
      expect(m.inboundQty, Decimal.fromInt(1), reason: 'what came in');
      expect(m.outboundQty, Decimal.fromInt(5), reason: 'what went back out');
      expect(m.purchaseReturnQty, Decimal.fromInt(5));
      // 5 bought and 2 returned is a net of 3 on the shelf, and the balance
      // side is what a stock position is built from.
      expect(m.inboundQty - m.outboundQty, Decimal.fromInt(-4));
    });
  });

  group('averageCostByItem', () {
    test('the average is the moving one, not the catalogue price', () async {
      // Bought 10 at ₹800, then 10 at ₹1000. The weighted average is ₹900 —
      // the *old* price, the *new* price, and the last-purchase price are all
      // different numbers, so a report that gets this wrong looks plausible.
      final supplier = await party('BuildMart');
      await bill(
        id: 'b1',
        date: DateTime(2026, 4, 1),
        partyId: supplier,
        quantity: '10',
        rate: '800',
      );
      await bill(
        id: 'b2',
        date: DateTime(2026, 5, 1),
        partyId: supplier,
        quantity: '10',
        rate: '1000',
      );

      final average = await averageCostByItem(db, firmId);
      expect(average[itemId], Decimal.fromInt(900));

      // `items.purchasePrice` is still ₹800 — the last one entered was not
      // written back to the master — which is exactly the field a naive report
      // reaches for. (`purchasePrice` is stored as a REAL, hence `800.0`.)
      final item = await storedItem(itemId);
      expect(item.purchasePrice, 800.0);
    });

    test(
      'the average is replayed over the whole log, not the window',
      () async {
        // The January purchase is outside the April-June window, but it is what
        // the June stock is worth. A windowed replay would value 10 bags bought in
        // April at nothing at all.
        final supplier = await party('BuildMart');
        await bill(
          id: 'b0',
          date: DateTime(2026, 1, 15),
          partyId: supplier,
          quantity: '10',
          rate: '500',
        );

        final average = await averageCostByItem(db, firmId);
        expect(average[itemId], Decimal.fromInt(500));

        final windowed = ReportWindow(
          preset: ReportWindowPreset.custom,
          from: DateTime(2026, 4, 1),
          to: DateTime(2026, 6, 30, 23, 59, 59),
        );
        final visible = (await movementsByItem(db, firmId, windowed))[itemId];
        expect(visible, isNull, reason: 'no movement in the window at all');
      },
    );
  });

  group('stock summary', () {
    test('closing stock is today\'s balance, not a sum of the window', () async {
      // Nothing happened in the window, so a movement sum is empty and a report
      // that used one would say the shelf is empty when 10 bags are on it.
      final supplier = await party('BuildMart');
      await bill(
        id: 'b0',
        date: DateTime(2026, 1, 15),
        partyId: supplier,
        quantity: '10',
        rate: '500',
      );

      final rows = (await run('stock_summary')).rows;
      final row = rows.firstWhere((r) => r.text(_col('item')) == 'Cement bag');
      expect(row.number(_col('stock')), Decimal.fromInt(10));
      expect(row.number(_col('in')), Decimal.fromInt(0));
      expect(row.number(_col('value')), Decimal.fromInt(5000));
    });

    test('an uncosted item is flagged rather than valued at nothing', () async {
      // Stock the firm has and has never priced: the opening quantity was typed
      // in and the purchase price was left blank, so there is no rate anywhere
      // to value it from. Printing ₹0 for ten bags of cement is a wrong answer
      // that looks like a right one — so it is valued at nothing *and named*,
      // which is a statement about the missing data rather than about the
      // stock.
      await items.create(
        name: 'Ghost bag',
        salePrice: 900,
        gstRate: 18,
        openingStock: 10,
      );

      final result = await run('stock_summary');
      final ghost = result.rows.firstWhere(
        (r) => r.text(_col('item')) == 'Ghost bag',
      );
      expect(ghost.number(_col('stock')), Decimal.fromInt(10));
      expect(ghost.number(_col('value')), Decimal.fromInt(0));
      expect(
        result.notes.where((n) => n.contains('Ghost bag')).toList(),
        isNotEmpty,
        reason: 'the uncosted item should be named in a note',
      );
    });
  });

  group('item wise P&L', () {
    test('cost is what left, not what was bought', () async {
      // Buy 10, sell 2. Cost of goods sold is 2 × 800 = 1,600 — the other 8 bags
      // are an asset. A report that used the purchase value would show a cost of
      // 8,000 against revenue of 2,000 and a profit that is actually a loss.
      final supplier = await party('BuildMart');
      final customer = await party('Beti Foods');
      await bill(
        id: 'b1',
        date: DateTime(2026, 4, 1),
        partyId: supplier,
        quantity: '10',
      );
      await invoice(
        id: 'i1',
        date: DateTime(2026, 5, 1),
        partyId: customer,
        quantity: '2',
      );

      final row = only(await run('item_wise_pnl'));
      expect(row.number(_col('sale')), Decimal.fromInt(2000));
      expect(row.number(_col('cost')), Decimal.fromInt(1600));
      expect(row.number(_col('profit')), Decimal.fromInt(400));
      expect(row.number(_col('margin')), Decimal.fromInt(20));
    });

    test('an item bought and never sold still appears', () async {
      // The union of both sides, not the sales map's keys — otherwise the
      // Purchases total in the report is short by exactly the items nobody
      // bought again.
      final supplier = await party('BuildMart');
      await bill(id: 'b1', date: DateTime(2026, 4, 1), partyId: supplier);
      await bill(
        id: 'b2',
        date: DateTime(2026, 4, 2),
        partyId: supplier,
        item: cheapId,
        quantity: '100',
        rate: '5',
        name: 'Bricks',
      );

      final rows = (await run('item_wise_pnl')).rows;
      // Present, with nothing earned. Iterating the *sales* map's keys instead
      // of the union drops this row entirely, and a firm that bought 100 bricks
      // would see a profit report that never mentions them.
      final bricks = rows.firstWhere((r) => r.text(_col('item')) == 'Bricks');
      expect(bricks.number(_col('sale')), Decimal.fromInt(0));
      expect(bricks.number(_col('profit')), Decimal.fromInt(0));

      // And where the report *does* have a purchase column, the figure is there
      // — this is where the omission of the item would actually show a total
      // short by 500.
      final sp = (await run('sp_by_item_category')).rows;
      final spBricks = sp.firstWhere((r) => r.text(_col('item')) == 'Bricks');
      expect(spBricks.number(_col('purchase')), Decimal.fromInt(500));
    });
  });

  group('percentages that do not terminate', () {
    test('a margin of one third prints, rather than throwing the report away', () {
      // ₹1 of profit on ₹3 of revenue is 33.333…%, a `Rational` with no finite
      // decimal expansion. `toDecimal()` with no `scaleOnInfinitePrecision`
      // **throws** on one — so the most ordinary margin in a shop, anything
      // involving a third, took the whole report down instead of printing 33.33.
      expect(
        marginPercent(Decimal.fromInt(1), Decimal.fromInt(3)),
        Decimal.parse('33.33'),
      );
      expect(
        marginPercent(Decimal.fromInt(2), Decimal.fromInt(3)),
        Decimal.parse('66.67'),
      );
      // A margin that does terminate is still exact, not rounded twice.
      expect(
        marginPercent(Decimal.fromInt(1), Decimal.fromInt(4)),
        Decimal.parse('25'),
      );
      expect(marginPercent(Decimal.fromInt(1), Decimal.zero), Decimal.zero);
    });

    test(
      'an invoice discount shared three ways does not throw either',
      () async {
        // Same defect by a different route: ₹10 off three equal lines is 3.333…
        // per line. The apportionment is the report's whole reason to exist, so
        // it has to survive a bill that divides badly.
        final customer = await party('Beti Foods');
        await sales.save(
          SalesDraft(
            id: 'i3',
            number: 'I3',
            invoiceDate: DateTime(2026, 4, 10),
            docType: 'invoice',
            partyId: customer,
            partyName: 'Customer',
            invoiceDiscountAmount: Decimal.fromInt(10),
            lines: [
              for (var i = 1; i <= 3; i++)
                SalesLineDraft(
                  id: 'i3-l$i',
                  itemId: itemId,
                  name: 'Cement bag',
                  hsn: '2523',
                  quantity: Decimal.fromInt(1),
                  unit: 'bag',
                  rate: Decimal.fromInt(1000),
                  gstRate: 18,
                ),
            ],
          ),
        );

        final row = only(await run('item_wise_discount'));
        expect(row.number(_col('discount')), Decimal.fromInt(10));
        expect(
          row.number(_col('percent')),
          Decimal.parse('0.33'),
          reason: '₹10 off ₹3,000 is a third of a percent',
        );
        expect(
          row.number(_col('gross')) - row.number(_col('discount')),
          row.number(_col('net')),
        );
      },
    );
  });

  group('item category reports', () {
    test('rows land in their category band', () async {
      final cement = await category('Cement');
      final steel = await category('Steel');
      final supplier = await party('BuildMart');
      await patchItem(itemId, (i) => i.copyWith(categoryId: Value(cement)));
      await patchItem(cheapId, (i) => i.copyWith(categoryId: Value(steel)));
      await bill(
        id: 'b1',
        date: DateTime(2026, 4, 1),
        partyId: supplier,
        quantity: '10',
      );
      await bill(
        id: 'b2',
        date: DateTime(2026, 4, 2),
        partyId: supplier,
        item: cheapId,
        quantity: '100',
        rate: '5',
        name: 'Bricks',
      );

      // The band is read off the **category cell**. A source that emitted the
      // item name in that cell would still fold into groups, but every row would
      // land in a bucket called "?" and the reader would see one number.
      final result = await run('item_category_pnl');
      expect(result.groups.map((g) => g.name).toSet(), {'Cement', 'Steel'});

      final stock = await run('stock_by_item_category');
      expect(stock.groups.map((g) => g.name).toSet(), {'Cement', 'Steel'});
    });

    test(
      'a service has no stock, so it is not in the stock valuation',
      () async {
        await items.create(
          name: 'Site supervision',
          isService: true,
          gstRate: 18,
          salePrice: 2000,
        );
        final rows = (await run('stock_by_item_category')).rows;
        expect(
          rows.where((r) => r.text(_col('item')) == 'Site supervision'),
          isEmpty,
          reason: 'a service on a stock valuation is a row of zeros',
        );
        // But it is trading, so it belongs in the P&L — a service business's whole
        // turnover would otherwise be absent from its own turnover report.
        final pnl = (await run('item_wise_pnl')).rows;
        expect(
          pnl.any((r) => r.text(_col('item')) == 'Site supervision'),
          isFalse,
          reason: 'it never traded in this window, so nothing to report',
        );
      },
    );
  });

  group('item report by party', () {
    test('a credit note stays a Sale row carrying a negative', () async {
      // Inferring the side from the sign would file every credit note under
      // "Purchase", which is not a cosmetic slip: the party's sale total would
      // show the sale but not its return.
      final customer = await party('Beti Foods');
      await invoice(id: 'i1', date: DateTime(2026, 4, 10), partyId: customer);
      await invoice(
        id: 'i2',
        date: DateTime(2026, 5, 10),
        partyId: customer,
        docType: 'credit_note',
      );

      final rows = (await run('item_report_by_party')).rows;
      final saleRows = rows
          .where((r) => r.text(_col('direction')) == 'Sale')
          .toList();
      expect(saleRows, hasLength(2));
      expect(saleRows.map((r) => r.number(_col('value'))).toList(), [
        Decimal.fromInt(1000),
        Decimal.fromInt(-1000),
      ]);
      expect(
        rows.every((r) => r.text(_col('party')) == 'Beti Foods'),
        isTrue,
        reason: 'the group cell must carry the party NAME, not its id',
      );
    });
  });

  group('item wise discount', () {
    test(
      'an invoice discount is apportioned and gross - discount = net',
      () async {
        // ₹100 off a ₹2,000 invoice. The report has to recompute the per-item
        // share rather than assume the engine stored it: `GstEngine` apportions
        // the header discount for tax and then discards the per-line result.
        final customer = await party('Beti Foods');
        await invoice(
          id: 'i1',
          date: DateTime(2026, 4, 10),
          partyId: customer,
          quantity: '2',
          rate: '1000',
          invoiceDiscountAmount: Decimal.fromInt(100),
        );

        final row = only(await run('item_wise_discount'));
        final gross = row.number(_col('gross'));
        final discount = row.number(_col('discount'));
        final net = row.number(_col('net'));
        expect(gross, Decimal.fromInt(2000));
        expect(discount, Decimal.fromInt(100));
        expect(net, Decimal.fromInt(1900));
        // Exact, not within a tolerance: the reader adds these columns up.
        expect(gross - discount, net);
      },
    );

    test('an inclusive-tax line gets the share off the back-calculated base, '
        'not the gross', () async {
      // With inclusive tax, `base.taxable` is a **back-calculated** figure
      // (`total / (1 + rate/100)`), not `gross − discount`. Any report that
      // recovered the document allowance by assuming a base of
      // `gross − lineDiscount` would be wrong here, and wrong in the way that
      // matters: the share would be a fraction of a number the tax was never
      // computed on, and every downstream margin shifts with it.
      //
      // ₹1,180 inclusive of 18% is ₹1,000 taxable. With a ₹100 document
      // allowance the line's stored taxable is ₹900 — so the share is **100**,
      // and only a base that came back out of the engine produces that. Taking
      // the gross as the base instead makes the share 1180 − 900 = **280**,
      // which is not an allowance of any kind: ₹100 of discount inflated by the
      // ₹180 of tax the customer paid on top of it.
      //
      // Note that `gross − discount == net` does **not** hold here, and should
      // not: gross is 1180 *including* ₹180 of tax, so it reconciles to the
      // taxable through the tax, not directly. That identity is an exclusive-line
      // property, and asserting it on an inclusive line would be asserting the
      // bug this delegation exists to avoid.
      final customer = await party('Beti Foods');
      await invoice(
        id: 'i4',
        date: DateTime(2026, 4, 10),
        partyId: customer,
        quantity: '1',
        rate: '1180',
        invoiceDiscountAmount: Decimal.fromInt(100),
        taxMode: TaxMode.inclusive,
      );

      final row = only(await run('item_wise_discount'));
      final gross = row.number(_col('gross'));
      final discount = row.number(_col('discount'));
      final net = row.number(_col('net'));
      expect(gross, Decimal.fromInt(1180), reason: 'quantity × rate');
      expect(discount, Decimal.fromInt(100), reason: 'the share as applied');
      expect(
        net,
        Decimal.fromInt(900),
        reason: 'taxable, net of the allowance',
      );
      // The base, recovered: 1180 gross, ₹180 of which is tax, is ₹1,000.
      // Asserted because it is the whole claim — a base of `gross − lineDiscount`
      // would be 1080 and the share would read 180.
      expect(
        gross - net - Decimal.fromInt(100),
        Decimal.fromInt(180),
        reason: 'the tax embedded in an inclusive gross',
      );
    });
  });

  group('stock detail', () {
    test('the opening balance is carried, and out-of-window rows are not '
        'counted as movement', () async {
      final supplier = await party('BuildMart');
      final customer = await party('Beti Foods');
      await bill(
        id: 'b0',
        date: DateTime(2026, 1, 15),
        partyId: supplier,
        quantity: '10',
        rate: '500',
      );
      await invoice(
        id: 'i1',
        date: DateTime(2026, 5, 1),
        partyId: customer,
        quantity: '2',
      );

      final rows = (await run('stock_detail')).rows;
      // **One row, not two.** The January purchase is outside the window, and
      // although the running balance needs it the row itself is not movement in
      // this period — a ledger listing an opening receipt under a heading that
      // says April to June is a ledger the reader cannot check. It is consumed
      // for the balance and then dropped.
      expect(rows, hasLength(1));
      // The balance after the sale is 8, and it comes from the ledger's own
      // running total rather than from `items.currentStock` — so a purchase
      // outside the window still counts towards the opening figure.
      final saleRow = rows.single;
      expect(saleRow.number(_col('balance')), Decimal.fromInt(8));
    });
  });

  group('low stock summary', () {
    test('Buy is the shortfall, and an item with no reorder level is never '
        'on the list', () async {
      final supplier = await party('BuildMart');
      // Cement: 10 on the shelf, reorder at 5 — comfortably stocked, so it must
      // not appear at all.
      await patchItem(itemId, (i) => i.copyWith(lowStockAlert: 5));
      await bill(
        id: 'b1',
        date: DateTime(2026, 4, 1),
        partyId: supplier,
        quantity: '10',
      );
      // Bricks: reorder at 200, nothing on the shelf. This is the whole report.
      await patchItem(cheapId, (i) => i.copyWith(lowStockAlert: 200));

      final rows = (await run('low_stock_summary')).rows;
      expect(rows, hasLength(1), reason: 'only the empty shelf is low');

      final bricks = rows.single;
      expect(bricks.text(_col('item')), 'Bricks');
      expect(bricks.number(_col('reorder')), Decimal.fromInt(200));
      expect(bricks.number(_col('stock')), Decimal.fromInt(0));
      // What to buy is the gap, not the level and not the stock.
      expect(bricks.number(_col('shortfall')), Decimal.fromInt(200));
      expect(
        rows.where((r) => r.text(_col('item')) == 'Cement bag'),
        isEmpty,
        reason: '10 bags on the shelf against a reorder level of 5',
      );
    });

    test('Buy is never negative', () async {
      // At exactly the reorder level the shortfall is zero, not −n: a negative
      // "Buy" has the reader ordering stock they already have.
      await patchItem(itemId, (i) => i.copyWith(lowStockAlert: 3));
      await bill(
        id: 'b1',
        date: DateTime(2026, 4, 1),
        partyId: await party('BuildMart'),
        quantity: '3',
      );

      final rows = (await run('low_stock_summary')).rows;
      final cement = rows.firstWhere(
        (r) => r.text(_col('item')) == 'Cement bag',
      );
      expect(cement.number(_col('stock')), Decimal.fromInt(3));
      expect(cement.number(_col('shortfall')), Decimal.fromInt(0));
    });
  });

  group('stock transfer', () {
    // **The movements are written straight to the table**, because no screen in
    // the app writes them yet — the godowns table and the `godownId` column
    // exist (schema v11) and this report reads them, but there is no transfer
    // entry UI. Writing them here keeps the *report* tested rather than
    // skipping it; what is untested is the transfer screen, and that is a gap in
    // the app rather than a gap in this report.
    test('both halves of a move between godowns, and a one-godown firm', () async {
      final store = await db
          .into(db.godowns)
          .insertReturning(
            GodownsCompanion.insert(
              id: 'g1',
              firmId: firmId,
              name: 'City store',
            ),
          );
      final warehouse = await db
          .into(db.godowns)
          .insertReturning(
            GodownsCompanion.insert(
              id: 'g2',
              firmId: firmId,
              name: 'Outback warehouse',
            ),
          );
      expect(store.name, 'City store');
      expect(warehouse.name, 'Outback warehouse');

      Future<void> move(String id, String kind, String? godownId, String qty) =>
          db
              .into(db.stockMovements)
              .insert(
                StockMovementsCompanion.insert(
                  id: id,
                  firmId: firmId,
                  itemId: itemId,
                  kind: kind,
                  quantity: double.parse(qty),
                  unitCost: const Value(800.0),
                  source: 'manual',
                  godownId: Value(godownId),
                  sourceNumber: const Value('TRF-1'),
                  date: DateTime(2026, 5, 5),
                ),
              );

      await move('m1', 'transfer_out', 'g1', '5');
      await move('m2', 'transfer_in', 'g2', '5');
      // A sale is not a transfer and must not appear here: it would make the
      // godown's receipts and issues balance against nothing.
      await move('m3', 'sale', 'g1', '-2');

      final rows = (await run('stock_transfer')).rows;
      expect(rows, hasLength(2));
      expect(rows.map((r) => r.text(_col('direction'))).toList(), [
        'Out',
        'In',
      ]);
      expect(rows.map((r) => r.text(_col('godown'))).toList(), [
        'City store',
        'Outback warehouse',
      ]);
      // Absolutised, with the sign carried by Direction: a reader scanning Qty
      // should see how much moved, not how it is stored.
      expect(rows.map((r) => r.number(_col('qty'))).toList(), [
        Decimal.fromInt(5),
        Decimal.fromInt(5),
      ]);
      expect(rows.first.number(_col('value')), Decimal.fromInt(4000));
      expect(rows.first.text(_col('number')), 'TRF-1');
    });

    test('a firm that never created a godown reads as Main, not blank', () async {
      // A null `godownId` is a location, not the absence of one. Reading it as
      // unknown would report a one-shop business as having no transfer history
      // at all — technically true and completely useless.
      await db
          .into(db.stockMovements)
          .insert(
            StockMovementsCompanion.insert(
              id: 'm1',
              firmId: firmId,
              itemId: itemId,
              kind: 'transfer_out',
              quantity: 3,
              unitCost: const Value(800.0),
              source: 'manual',
              date: DateTime(2026, 5, 5),
            ),
          );

      final rows = (await run('stock_transfer')).rows;
      expect(rows, hasLength(1));
      expect(rows.single.text(_col('godown')), 'Main');
    });
  });

  group('every Item/Stock report', () {
    test('integrity: subtotals sum exactly to the grand total', () async {
      final supplier = await party('BuildMart');
      final customer = await party('Beti Foods');
      final cement = await category('Cement');
      await patchItem(itemId, (i) => i.copyWith(categoryId: Value(cement)));
      await bill(
        id: 'b1',
        date: DateTime(2026, 4, 1),
        partyId: supplier,
        quantity: '10',
      );
      await invoice(
        id: 'i1',
        date: DateTime(2026, 5, 1),
        partyId: customer,
        quantity: '2',
      );
      await invoice(
        id: 'i2',
        date: DateTime(2026, 6, 1),
        partyId: customer,
        docType: 'credit_note',
      );

      // A reorder level above what the fixture bought, so the Low Stock report
      // has something to say. Without it every item sits comfortably above zero
      // and the report is honestly empty — which is a correct answer, not a
      // failure, but it leaves the report untested.
      await patchItem(itemId, (i) => i.copyWith(lowStockAlert: 50));

      const ids = [
        'stock_summary',
        'item_report_by_party',
        'item_wise_pnl',
        'item_category_pnl',
        'low_stock_summary',
        'stock_detail',
        'item_detail',
        'sp_by_item_category',
        'stock_by_item_category',
        'item_wise_discount',
      ];
      for (final id in ids) {
        final result = await run(id);
        expect(result.count, greaterThan(0), reason: '$id produced nothing');
      }
    });

    test('a window with nothing in it produces no rows, not zeroes', () async {
      final empty = ReportWindow(
        preset: ReportWindowPreset.custom,
        from: DateTime(2025, 1, 1),
        to: DateTime(2025, 1, 31, 23, 59, 59),
      );
      for (final id in [
        'item_wise_pnl',
        'item_report_by_party',
        'item_wise_discount',
        'stock_detail',
        'stock_transfer',
      ]) {
        final result = await run(id, over: empty);
        expect(
          result.rows,
          isEmpty,
          reason: '$id printed a row of zeroes for a month with no business',
        );
      }
    });
  });
}

/// The column descriptor for [key], with the kind the reports actually use.
ReportColumn _col(String key) => ReportColumn(
  key: key,
  label: key,
  kind: switch (key) {
    'stock' ||
    'in' ||
    'out' ||
    'saleQty' ||
    'qty' ||
    'balance' ||
    'buy' ||
    'reorder' => ReportValueKind.quantity,
    'margin' || 'percent' => ReportValueKind.percent,
    'rate' => ReportValueKind.rate,
    _ => ReportValueKind.money,
  },
);
