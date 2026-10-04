import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/reports/sources/item_stock/item_common.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared layer under the eleven Item/Stock reports.
///
/// These exist because every one of the eleven asks the same four questions of
/// the same tables. A shared helper that is subtly wrong is worse than eleven
/// wrong reports, because it is wrong *consistently* — so the sign rules and the
/// union behaviour are pinned here rather than in whichever report happened to
/// be written first.
void main() {
  late AppDatabase db;
  late String firmId;
  late SalesRepository sales;
  late PurchaseRepository purchases;
  late String itemId;

  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    addTearDown(db.close);
    firmId = (await db.firmRepository.create(name: 'Test', stateCode: '29')).id;
    sales = db.salesRepositoryFor(firmId);
    purchases = db.purchaseRepositoryFor(firmId);
    final item = await db.itemRepositoryFor(firmId).create(
      name: 'Cement bag',
      hsn: '2523',
      purchasePrice: 80,
      salePrice: 100,
      gstRate: 18,
      openingStock: 10,
    );
    itemId = item.id;
  });

  Future<void> invoice({
    required String id,
    required DateTime date,
    String quantity = '2',
    String rate = '100',
    String docType = 'invoice',
  }) =>
      sales.save(
        SalesDraft(
          id: id,
          number: id.toUpperCase(),
          invoiceDate: date,
          docType: docType,
          partyId: 'p1',
          partyName: 'Customer',
          lines: [
            SalesLineDraft(
              id: '$id-l1',
              itemId: itemId,
              name: 'Cement bag',
              hsn: '2523',
              quantity: Decimal.parse(quantity),
              unit: 'bag',
              rate: Decimal.parse(rate),
              gstRate: 18,
            ),
          ],
        ),
      );

  Future<void> bill({
    required String id,
    required DateTime date,
    String quantity = '5',
    String rate = '80',
    String docType = 'bill',
  }) =>
      purchases.save(
        PurchaseDraft(
          id: id,
          number: id.toUpperCase(),
          billDate: date,
          docType: docType,
          partyId: 's1',
          partyName: 'Supplier',
          lines: [
            PurchaseLineDraft(
              id: '$id-l1',
              itemId: itemId,
              name: 'Cement bag',
              hsn: '2523',
              quantity: Decimal.parse(quantity),
              unit: 'bag',
              rate: Decimal.parse(rate),
              gstRate: 18,
            ),
          ],
        ),
      );

  group('movementsByItem', () {
    test('a purchase arrives and a sale leaves, at the cost it moved at', () async {
      await bill(id: 'pb-1', date: DateTime(2026, 4, 5), quantity: '5');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), quantity: '2');

      final by = await movementsByItem(db, firmId, window);
      final m = by[itemId]!;
      // **5, not 15.** The opening movement is stamped at item creation, which
      // is today -- outside this window. A test that expected the opening inside
      // it would be asserting the bug, and the bug is the one that makes a Stock
      // Summary report an item created last year as having nothing on the shelf.
      // The balance comes from `items.currentStock` via [infoFor] instead.
      expect(m.inboundQty, Decimal.fromInt(5));
      expect(m.outboundQty, Decimal.fromInt(2));
      expect(m.inboundValue, Decimal.fromInt(400));
      expect(m.saleQty, Decimal.fromInt(2));
      expect(m.saleValue, Decimal.fromInt(160));
    });

    test('the balance is the master, and it moves with the ledger', () async {
      // The counterpart to the assertion above: where the window cannot say what
      // is on the shelf, the master can, and it must agree with the movements.
      final before = infoFor((await allLiveItems(db, firmId))[itemId]!);
      expect(before.currentStock, Decimal.fromInt(10), reason: 'opening');

      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), quantity: '2');
      await bill(id: 'pb-1', date: DateTime(2026, 4, 12), quantity: '5');

      final after = infoFor((await allLiveItems(db, firmId))[itemId]!);
      expect(after.currentStock, Decimal.fromInt(13), reason: '10 - 2 + 5');
      final flow = (await movementsByItem(db, firmId, window))[itemId]!;
      expect(
        after.currentStock - before.currentStock,
        flow.inboundQty - flow.outboundQty,
        reason: 'the cache and the movement log must not disagree',
      );
    });

    test('a credit note brings stock back at the cost it went out at', () async {
      // The return's movement is a positive quantity against a positive cost, so
      // it nets against the sale exactly. Valued from a catalogue price instead,
      // the return would carry a different cost and the margin would not mirror.
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), quantity: '2');
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 4, 20),
        quantity: '1',
        docType: 'credit_note',
      );

      // Sold and returned are **separate columns, not one netted figure**. A
      // report that showed only the net would hide a returned item behind a
      // sale that never happened; showing only the gross would overstate both
      // the quantity and the margin. Net is the reader's subtraction.
      final m = (await movementsByItem(db, firmId, window))[itemId]!;
      expect(m.saleQty, Decimal.fromInt(2), reason: 'gross sold');
      expect(m.saleReturnQty, Decimal.fromInt(1));
      expect(m.saleQty - m.saleReturnQty, Decimal.fromInt(1), reason: 'net sold');
      expect(m.saleValue, Decimal.fromInt(160));
      expect(m.saleReturnValue, Decimal.fromInt(80), reason: 'at the cost it left at');
      // And the return puts stock *back*, so it is inbound rather than another
      // outbound — which is what makes `inbound - outbound` agree with the
      // change in `items.currentStock`.
      expect(m.inboundQty, Decimal.fromInt(1));
      expect(m.outboundQty, Decimal.fromInt(2));
    });

    test('a debit note takes stock back off the shelf', () async {
      // A purchase return is a real stock movement. Ignoring it would leave the
      // shelf showing goods the supplier took back.
      await bill(id: 'pb-1', date: DateTime(2026, 4, 5), quantity: '5');
      await bill(
        id: 'dn-1',
        date: DateTime(2026, 4, 8),
        quantity: '2',
        docType: 'debit_note',
      );

      final m = (await movementsByItem(db, firmId, window))[itemId]!;
      expect(m.inboundQty, Decimal.fromInt(5), reason: 'what came in');
      expect(m.outboundQty, Decimal.fromInt(2), reason: 'what went back out');
      expect(m.purchaseReturnQty, Decimal.fromInt(2));
      expect(
        m.inboundQty - m.outboundQty,
        Decimal.fromInt(3),
        reason: '5 bought, 2 returned',
      );
    });

    test('the window excludes a movement outside it', () async {
      await invoice(id: 'inv-in', date: DateTime(2026, 5, 1));
      await invoice(id: 'inv-out', date: DateTime(2026, 1, 5), quantity: '9');

      final m = (await movementsByItem(db, firmId, window))[itemId]!;
      expect(m.saleQty, Decimal.fromInt(2));
    });

    test('scoping to one item returns only that item', () async {
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10));
      final by = await movementsByItem(db, firmId, window, selected: itemId);
      expect(by.keys, contains(itemId));
      expect(by[itemId]!.saleQty, Decimal.fromInt(2));
    });
  });

  group('tradingByItem', () {
    test('sales and purchases land on one row per item', () async {
      // The union, not one map's keys: an item bought and never sold is absent
      // from the sales result, and iterating that alone drops it from the report
      // and makes the Purchases total short by exactly it.
      await bill(id: 'pb-1', date: DateTime(2026, 4, 5), quantity: '5');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), quantity: '2');

      final by = await tradingByItem(db, firmId, window);
      expect(by[itemId], isNotNull);
      expect(by[itemId]!.saleValue, Decimal.fromInt(200));
      expect(by[itemId]!.purchaseValue, Decimal.fromInt(400));
    });

    test('value is taxable, so output tax is not counted as revenue', () async {
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), quantity: '2');
      final t = (await tradingByItem(db, firmId, window))[itemId]!;
      expect(t.saleValue, Decimal.fromInt(200), reason: 'taxable, not 236');
      expect(t.saleTax, Decimal.fromInt(36));
    });

    test('a credit note nets out of both quantity and value', () async {
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), quantity: '3');
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 4, 20),
        quantity: '1',
        docType: 'credit_note',
      );

      final t = (await tradingByItem(db, firmId, window))[itemId]!;
      expect(t.saleQty, Decimal.fromInt(2), reason: '3 sold, 1 returned');
      expect(t.saleValue, Decimal.fromInt(200));
      // Tax nets too — the same trap the party tax fix closed, on the line
      // tables this time. 3 x 18 = 54, less 18 for the return.
      expect(t.saleTax, Decimal.fromInt(36));
    });

    test('a soft-deleted invoice is excluded', () async {
      // Deleted and cancelled are separate predicates; a document can be in the
      // recycle bin without being cancelled, and reports must respect both.
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), quantity: '2');
      await invoice(id: 'inv-2', date: DateTime(2026, 4, 11), quantity: '5');
      await sales.softDelete('inv-2');

      final t = (await tradingByItem(db, firmId, window))[itemId]!;
      expect(t.saleQty, Decimal.fromInt(2));
    });

    test('a quotation is not a transaction', () async {
      // A quotation has a quantity and a rate and money neither earned nor owed.
      await sales.save(
        SalesDraft(
          id: 'q-1',
          number: 'Q-1',
          invoiceDate: DateTime(2026, 4, 12),
          docType: 'quotation',
          partyId: 'p1',
          partyName: 'Customer',
          lines: [
            SalesLineDraft(
              id: 'q-1-l1',
              itemId: itemId,
              name: 'Cement bag',
              hsn: '2523',
              quantity: Decimal.fromInt(50),
              unit: 'bag',
              rate: Decimal.fromInt(100),
              gstRate: 18,
            ),
          ],
        ),
      );

      final by = await tradingByItem(db, firmId, window);
      expect(by[itemId], isNull, reason: 'a quotation is not revenue');
    });
  });

  group('the item pickers and categories', () {
    test('options are live items in name order, deleted excluded', () async {
      final second = await db
          .itemRepositoryFor(firmId)
          .create(name: 'Aardvark', hsn: '2523', gstRate: 18);
      final gone = await db
          .itemRepositoryFor(firmId)
          .create(name: 'Zzz deleted', hsn: '2523', gstRate: 18);
      await db.itemRepositoryFor(firmId).delete(gone.id);

      final options = await itemFilterOptions(db, firmId);
      final names = options.map((o) => o.label).toList();
      expect(names, ['Aardvark', 'Cement bag']);
      expect(names, isNot(contains('Zzz deleted')));
      expect(options.map((o) => o.value), contains(second.id));
    });

    test('a category report buckets every item, including uncategorised', () async {
      // Dropping null categories would total short by exactly the products
      // nobody has classified — true of every item in every firm that has not
      // set up categories.
      final live = await allLiveItems(db, firmId);
      final names = await itemCategoryNames(db, firmId, live);
      expect(names[itemId], 'Ungrouped');
    });

    test('a service is filed under Services, not Ungrouped', () async {
      // "This product has no category" and "this line is not a product" are
      // different statements, and one bucket that means both makes the
      // ungrouped row unreadable.
      final service = await db.itemRepositoryFor(firmId).create(
        name: 'Consulting',
        isService: true,
        gstRate: 18,
      );
      final live = await allLiveItems(db, firmId);
      final names = await itemCategoryNames(db, firmId, live);
      expect(names[service.id], 'Services');
      expect(names[itemId], 'Ungrouped');
    });

    test('a real category name wins over the fallback', () async {
      final category = await db
          .itemRepositoryFor(firmId)
          .createCategory('Cement', kind: 'item');
      await db.itemRepositoryFor(firmId).update(
        (await db.itemRepositoryFor(firmId).getById(itemId))!
            .copyWith(categoryId: Value(category.id)),
      );
      final live = await allLiveItems(db, firmId);
      final names = await itemCategoryNames(db, firmId, live);
      expect(names[itemId], 'Cement');
    });
  });

  group('low stock', () {
    Future<ItemInfo> info() async =>
        infoFor((await allLiveItems(db, firmId))[itemId]!);

    test('an item under its reorder level is low', () async {
      await db.itemRepositoryFor(firmId).update(
        (await db.itemRepositoryFor(firmId).getById(itemId))!
            .copyWith(lowStockAlert: 15.0),
      );
      final i = await info();
      expect(i.currentStock, Decimal.fromInt(10));
      expect(i.lowStockAlert, Decimal.fromInt(15));
      expect(
        i.isLowStock,
        isTrue,
        reason: '10 on the shelf against a reorder level of 15',
      );
    });

    test('an item over its level is not low', () async {
      await db.itemRepositoryFor(firmId).update(
        (await db.itemRepositoryFor(firmId).getById(itemId))!
            .copyWith(lowStockAlert: 5.0),
      );
      expect((await info()).isLowStock, isFalse);
    });

    test('no reorder level means NOT low, rather than low at zero', () async {
      // The trap. `lowStockAlert == 0` is the absence of a threshold, not a
      // threshold of zero — and treating it as one puts every item in the
      // catalogue on the Low Stock Summary, which is a report nobody reads.
      expect((await info()).lowStockAlert, Decimal.zero);
      expect(
        (await info()).isLowStock,
        isFalse,
        reason: 'a firm that configured no reorder levels has nothing to report',
      );
    });
  });

  group('uncostedNote', () {
    test('says nothing when nothing is uncosted', () {
      expect(uncostedNote(const []), isEmpty);
    });

    test('names the items, capped, and does not pretend it is a result', () {
      final note = uncostedNote(const ['A', 'B', 'C']).join(' ');
      expect(note, contains('No cost of goods recorded'));
      expect(note, contains('A, B, C'));
    });
  });
}