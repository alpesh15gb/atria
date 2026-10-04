import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/costing/moving_average.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/schema_rollback.dart';

/// The two rules that make weighted moving average safe to build 47 reports on.
///
///  * **The accumulator is never rounded.** Rounding after every movement drifts
///    by tens of paise a year, and drift in a stock valuation is a number that
///    never agrees with the physical count.
///  * **Negative stock never divides.** The ledger deliberately allows billing
///    before buying, so the balance can go negative — and `value / quantity`
///    on a negative balance is a negative cost, which turns every downstream
///    margin upside down.
///
/// Plus the stamping that connects them to the database: what a purchase and a
/// sale actually write onto the movement row.
void main() {
  late AppDatabase db;
  String firmId = '';

  CostedMovement in_(String id, double quantity, {String? cost}) =>
      CostedMovement(
        id: id,
        kind: 'purchase',
        quantity: quantity,
        unitCost: cost == null ? null : Decimal.parse(cost),
      );

  CostedMovement out(String id, double quantity, {String? cost}) =>
      CostedMovement(
        id: id,
        kind: 'sale',
        quantity: -quantity,
        unitCost: cost == null ? null : Decimal.parse(cost),
      );

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firmId = (await db.firmRepository.create(name: 'Alpha Traders')).id;
  });

  tearDown(() => db.close());

  group('the arithmetic', () {
    test(
      'an item that has never been bought has no cost, not a cost of zero',
      () {
        final costing = MovingAverageCosting.initial();
        // Zero is a claim, and it is false here: nothing is known. Reports
        // print "—" for a null cost and "0.00" for a real one, and those mean
        // opposite things.
        expect(costing.average, isNull);
        expect(MovingAverageCosting.report(costing.average), isNull);
      },
    );

    test('the first purchase sets the average', () {
      final (next, stamped) = MovingAverageCosting.initial().apply(
        in_('m1', 10, cost: '25'),
      );

      expect(stamped, Decimal.fromInt(25));
      expect(next.quantity, Decimal.fromInt(10));
      expect(next.average, Decimal.parse('25.0000'));
    });

    test(
      'a second purchase at a different price re-averages the whole stock',
      () {
        var costing = MovingAverageCosting.initial();
        (costing, _) = costing.apply(in_('m1', 10, cost: '20'));
        final (after, stamped) = costing.apply(in_('m2', 10, cost: '30'));

        // 200 of value over 20 units, not 30 — the goods already in stock were
        // not revalued at the new price.
        expect(stamped, Decimal.fromInt(30));
        expect(after.quantity, Decimal.fromInt(20));
        expect(after.average, Decimal.parse('25.0000'));
      },
    );

    test('goods leaving stock are valued at the average of what is left', () {
      var costing = MovingAverageCosting.initial();
      (costing, _) = costing.apply(in_('m1', 10, cost: '20'));
      (costing, _) = costing.apply(in_('m2', 10, cost: '30'));
      final (after, stamped) = costing.apply(out('m3', 5));

      expect(stamped, Decimal.parse('25.0000'));
      expect(after.quantity, Decimal.fromInt(15));
      // 500 - 125 = 375 over 15.
      expect(after.average, Decimal.parse('25.0000'));
    });

    test('an unequal split moves the average without moving the value', () {
      var costing = MovingAverageCosting.initial();
      (costing, _) = costing.apply(in_('m1', 10, cost: '20'));
      (costing, _) = costing.apply(out('m2', 4));
      final (after, _) = costing.apply(in_('m3', 10, cost: '30'));

      // 120 left, +300 in = 420 over 16 = 26.25.
      expect(after.quantity, Decimal.fromInt(16));
      expect(after.average, Decimal.parse('26.2500'));
    });

    test('an outbound movement already carrying a cost keeps the average, '
        'not its own', () {
      var costing = MovingAverageCosting.initial();
      (costing, _) = costing.apply(in_('m1', 10, cost: '20'));
      (costing, _) = costing.apply(in_('m2', 10, cost: '30'));
      // The average is 25. This row claims 999.
      final (_, stamped) = costing.apply(out('m3', 5, cost: '999'));

      // A reversal carries the cost of the movement it reverses, which is
      // right *for that reversal*. If it won here, deleting and re-saving an
      // invoice would restate the cost of goods that never moved.
      expect(stamped, Decimal.parse('25.0000'));
    });

    test('a movement of nothing changes nothing', () {
      var costing = MovingAverageCosting.initial();
      (costing, _) = costing.apply(in_('m1', 10, cost: '20'));
      final (after, stamped) = costing.apply(
        const CostedMovement(id: 'm2', kind: 'transfer', quantity: 0),
      );

      expect(stamped, Decimal.parse('20.0000'));
      expect(after.average, costing.average);
      expect(after.quantity, Decimal.fromInt(10));
    });
  });

  group('negative stock', () {
    test('billing before buying does not produce a negative cost', () {
      var costing = MovingAverageCosting.initial();
      (costing, _) = costing.apply(in_('m1', 10, cost: '20'));
      final (after, stamped) = costing.apply(out('m2', 15));

      // Stock has gone to -5. The cost of the goods that left is the average
      // that applied while they were still there — a negative number here
      // would report the sale at a negative margin.
      expect(stamped, Decimal.parse('20.0000'));
      expect(stamped, greaterThanOrEqualTo(Decimal.zero));
      expect(after.average, Decimal.parse('20.0000'));
      expect(
        after.usedFallback,
        isTrue,
        reason: 'the figure is carried forward, not computed',
      );
    });

    test('stock that goes negative and comes back re-averages against the '
        'shortfall', () {
      var costing = MovingAverageCosting.initial();
      (costing, _) = costing.apply(in_('m1', 10, cost: '20'));
      (costing, _) = costing.apply(out('m2', 15));
      final (after, _) = costing.apply(in_('m3', 10, cost: '30'));

      // The 5 oversold units were valued at 20 each, so the shop owes 100 for
      // goods it has already delivered. It pays 300 for 10 more and settles
      // the debt with 5 of them, which leaves 5 units that genuinely cost 200.
      //
      // Valuing them at the full 30 each — as though the shortfall had cost
      // nothing — is the number that makes a shop's stock valuation drift away
      // from its bank balance by exactly the amount it owes.
      expect(after.quantity, Decimal.fromInt(5));
      expect(after.value, Decimal.fromInt(200));
      expect(after.average, Decimal.parse('40.0000'));
    });

    test('an item oversold from nothing is valued at zero, honestly', () {
      var costing = MovingAverageCosting.initial();
      final (_, stamped) = costing.apply(out('m1', 5));

      // Nothing was ever bought, so nothing is known. Zero is recorded rather
      // than guessed at, and the reports show the missing cost.
      expect(stamped, Decimal.zero);
    });

    test(
      'an inbound movement with no recorded cost falls back to the average',
      () {
        var costing = MovingAverageCosting.initial();
        (costing, _) = costing.apply(in_('m1', 10, cost: '20'));
        final (after, stamped) = costing.apply(in_('m2', 10));

        // Better a slightly wrong known cost than a zero that would wipe the
        // average out and make the whole stock look worthless.
        expect(stamped, Decimal.parse('20.0000'));
        expect(after.usedFallback, isTrue);
        expect(after.average, Decimal.parse('20.0000'));
      },
    );
  });

  group('precision', () {
    test('the accumulator keeps four places and does not drift', () {
      // 3 at 10, then 3 at 10.01. The true average is 10.005, which is not
      // representable in two places. Rounding the *stored* average after each
      // movement is what makes a year of this end up wrong.
      final costs = replay([
        in_('m1', 3, cost: '10'),
        in_('m2', 3, cost: '10.01'),
      ]);

      expect(costs['m1'], Decimal.fromInt(10));
      expect(costs['m2'], Decimal.parse('10.0100'));

      var costing = MovingAverageCosting.initial();
      (costing, _) = costing.apply(in_('m1', 3, cost: '10'));
      (costing, _) = costing.apply(in_('m2', 3, cost: '10.01'));

      expect(costing.average, Decimal.parse('10.0050'));
      // Only the reported figure is rounded.
      expect(
        MovingAverageCosting.report(costing.average),
        Decimal.parse('10.01'),
      );
    });

    test('many small movements do not accumulate rounding error', () {
      // The shape that actually drifts: a shop buying 1 unit at a time at a
      // price that does not divide evenly.
      final moves = <CostedMovement>[];
      for (var i = 0; i < 200; i++) {
        moves.add(in_('m$i', 1, cost: i.isEven ? '10.005' : '9.995'));
      }
      final costs = replay(moves);

      var costing = MovingAverageCosting.initial();
      for (final move in moves) {
        (costing, _) = costing.apply(move);
      }

      // 100 lots at 10.005 and 100 at 9.995 is exactly 1000 over 200 = 5.
      // A two-place accumulator would have landed somewhere else entirely.
      expect(costing.average, Decimal.parse('10.0000'));
      expect(costs.length, 200);
      expect(costs['m199'], Decimal.parse('9.9950'));
    });

    test('replay gives the same answer twice', () {
      final moves = [
        in_('m1', 10, cost: '20'),
        out('m2', 4),
        in_('m3', 6, cost: '33.33'),
        out('m4', 5),
      ];
      expect(replay(moves), replay(moves));
    });
  });

  group('what a document actually writes onto the movement', () {
    Future<String> makeItem({double purchasePrice = 0}) async =>
        (await db
                .itemRepositoryFor(firmId)
                .create(name: 'Widget', purchasePrice: purchasePrice))
            .id;

    test(
      'a purchase is stamped with the bill line cost, excluding GST',
      () async {
        final itemId = await makeItem();
        final purchases = db.purchaseRepositoryFor(firmId);

        // 10 units at 100 = 1000 taxable, plus 18% GST = 1180 payable.
        // Stamping 118 (the total) would capitalise the input tax credit into
        // stock and overstate the cost of every sale by 18%.
        await purchases.save(
          PurchaseDraft(
            id: 'bill-1',
            number: 'PUR-001',
            billDate: DateTime(2026, 4, 1),
            docType: 'bill',
            lines: [
              PurchaseLineDraft(
                id: 'bl-1',
                itemId: itemId,
                name: 'Widget',
                quantity: Decimal.fromInt(10),
                unit: 'pcs',
                rate: Decimal.fromInt(100),
                gstRate: 18,
              ),
            ],
          ),
        );

        final movement = await (db.select(
          db.stockMovements,
        )..where((t) => t.sourceId.equals('bill-1'))).getSingle();
        expect(movement.unitCost, closeTo(100.0, 0.0001));
        expect(movement.quantity, 10);
        expect(
          movement.sourceLineId,
          'bl-1',
          reason: 'the line is what makes the cost provable on a re-run',
        );
      },
    );

    test(
      'a purchase return is valued at the average, not at its own rate',
      () async {
        final itemId = await makeItem();
        final purchases = db.purchaseRepositoryFor(firmId);
        await purchases.save(
          PurchaseDraft(
            id: 'bill-1',
            number: 'PUR-001',
            billDate: DateTime(2026, 4, 1),
            docType: 'bill',
            lines: [
              PurchaseLineDraft(
                id: 'bl-1',
                itemId: itemId,
                name: 'Widget',
                quantity: Decimal.fromInt(10),
                unit: 'pcs',
                rate: Decimal.fromInt(100),
                gstRate: 18,
              ),
            ],
          ),
        );

        await purchases.save(
          PurchaseDraft(
            id: 'dn-1',
            number: 'DN-001',
            docType: 'debit_note',
            billDate: DateTime(2026, 4, 5),
            lines: [
              PurchaseLineDraft(
                id: 'dnl-1',
                itemId: itemId,
                name: 'Widget',
                quantity: Decimal.fromInt(4),
                unit: 'pcs',
                // Deliberately not 100. A supplier who returns goods at a
                // negotiated price does not restate what the stock in the shop
                // was originally worth.
                rate: Decimal.fromInt(180),
                gstRate: 18,
              ),
            ],
          ),
        );

        final movement = await (db.select(
          db.stockMovements,
        )..where((t) => t.sourceId.equals('dn-1'))).getSingle();
        expect(movement.quantity, -4);
        // The 180 is what the supplier charged for the return. The 100 is what
        // the goods leaving the shop are worth, which is a different question —
        // and it is the one the P&L and the stock report ask.
        expect(movement.unitCost, closeTo(100.0, 0.0001));
      },
    );

    test(
      'a sale is stamped with the running average, not with the sale price',
      () async {
        final itemId = await makeItem();
        final purchases = db.purchaseRepositoryFor(firmId);
        final sales = db.salesRepositoryFor(firmId);

        await purchases.save(
          PurchaseDraft(
            id: 'bill-1',
            number: 'PUR-001',
            billDate: DateTime(2026, 4, 1),
            docType: 'bill',
            lines: [
              PurchaseLineDraft(
                id: 'bl-1',
                itemId: itemId,
                name: 'Widget',
                quantity: Decimal.fromInt(10),
                unit: 'pcs',
                rate: Decimal.fromInt(100),
                gstRate: 18,
              ),
            ],
          ),
        );
        await purchases.save(
          PurchaseDraft(
            id: 'bill-2',
            number: 'PUR-002',
            docType: 'bill',
            billDate: DateTime(2026, 4, 2),
            lines: [
              PurchaseLineDraft(
                id: 'bl-2',
                itemId: itemId,
                name: 'Widget',
                quantity: Decimal.fromInt(10),
                unit: 'pcs',
                rate: Decimal.fromInt(200),
                gstRate: 18,
              ),
            ],
          ),
        );

        await sales.save(
          SalesDraft(
            id: 'inv-1',
            number: 'INV-001',
            invoiceDate: DateTime(2026, 4, 5),
            docType: 'invoice',
            lines: [
              SalesLineDraft(
                id: 'sl-1',
                itemId: itemId,
                name: 'Widget',
                quantity: Decimal.fromInt(5),
                unit: 'pcs',
                rate: Decimal.fromInt(500),
                gstRate: 18,
              ),
            ],
          ),
        );

        final movement = await (db.select(
          db.stockMovements,
        )..where((t) => t.sourceId.equals('inv-1'))).getSingle();
        // 1000 + 2000 = 3000 over 20 units = 150, not the last bill's 200 and
        // certainly not the 500 the customer paid.
        expect(movement.unitCost, closeTo(150.0, 0.0001));
      },
    );

    test('reversing a sale copies the cost it reversed', () async {
      final itemId = await makeItem();
      final purchases = db.purchaseRepositoryFor(firmId);
      final sales = db.salesRepositoryFor(firmId);

      await purchases.save(
        PurchaseDraft(
          id: 'bill-1',
          number: 'PUR-001',
          billDate: DateTime(2026, 4, 1),
          docType: 'bill',
          lines: [
            PurchaseLineDraft(
              id: 'bl-1',
              itemId: itemId,
              name: 'Widget',
              quantity: Decimal.fromInt(10),
              unit: 'pcs',
              rate: Decimal.fromInt(100),
              gstRate: 18,
            ),
          ],
        ),
      );
      await sales.save(
        SalesDraft(
          id: 'inv-1',
          number: 'INV-001',
          invoiceDate: DateTime(2026, 4, 5),
          docType: 'invoice',
          lines: [
            SalesLineDraft(
              id: 'sl-1',
              itemId: itemId,
              name: 'Widget',
              quantity: Decimal.fromInt(5),
              unit: 'pcs',
              rate: Decimal.fromInt(500),
              gstRate: 18,
            ),
          ],
        ),
      );

      await sales.softDelete('inv-1');

      final all = await db.select(db.stockMovements).get();
      all.sort((a, b) => a.date.compareTo(b.date));
      final sale = all.firstWhere((m) => m.sourceId == 'inv-1');
      final reversal = all.firstWhere(
        (m) => m.kind == 'sale_return' && m.id != sale.id,
        orElse: () => all.last,
      );

      // Re-valuing the reversal at today's average would make the pair
      // asymmetric and leak cost onto the books on every edit.
      expect(reversal.unitCost, closeTo(sale.unitCost, 0.0001));
    });
  });

  group('the backfill', () {
    /// A movement a current build would have written, line reference and all.
    Future<void> writeMovement({
      required String id,
      required String itemId,
      required String kind,
      required double quantity,
      required String sourceId,
      required DateTime date,
      String? sourceLineId,
    }) => db
        .into(db.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            id: id,
            firmId: firmId,
            itemId: itemId,
            kind: kind,
            quantity: quantity,
            source: sourceId.startsWith('bill-')
                ? 'purchase_bills'
                : 'sales_invoices',
            sourceId: Value(sourceId),
            sourceLineId: Value(sourceLineId),
            date: date,
          ),
        );

    /// The same, as a pre-costing build would have left it: unit cost zero,
    /// no line reference.
    Future<void> writeLegacyMovement({
      required String id,
      required String itemId,
      required String kind,
      required double quantity,
      required String sourceId,
      required DateTime date,
    }) => writeMovement(
      id: id,
      itemId: itemId,
      kind: kind,
      quantity: quantity,
      sourceId: sourceId,
      date: date,
    );

    Future<void> writeBill({
      required String id,
      required List<({String id, String? itemId, double qty, double taxable})>
      lines,
    }) async {
      await db
          .into(db.purchaseBills)
          .insert(
            PurchaseBillsCompanion.insert(
              id: id,
              firmId: firmId,
              number: id.toUpperCase(),
              billDate: DateTime(2026, 4, 1),
            ),
          );
      var order = 0;
      for (final line in lines) {
        await db
            .into(db.purchaseBillItems)
            .insert(
              PurchaseBillItemsCompanion.insert(
                id: line.id,
                billId: id,
                itemId: Value(line.itemId),
                name: 'Widget',
                quantity: line.qty,
                rate: line.taxable / line.qty,
                taxableValue: Value(line.taxable),
                sortOrder: Value(order++),
              ),
            );
      }
    }

    test(
      'history written before costing is priced from the bills that made it',
      () async {
        final itemId =
            (await db.itemRepositoryFor(firmId).create(name: 'Widget')).id;

        await writeBill(
          id: 'bill-1',
          lines: [(id: 'bl-1', itemId: itemId, qty: 10, taxable: 1000)],
        );
        await writeBill(
          id: 'bill-2',
          lines: [(id: 'bl-2', itemId: itemId, qty: 10, taxable: 3000)],
        );
        await writeLegacyMovement(
          id: 'mv-1',
          itemId: itemId,
          kind: 'purchase',
          quantity: 10,
          sourceId: 'bill-1',
          date: DateTime(2026, 4, 1),
        );
        await writeLegacyMovement(
          id: 'mv-2',
          itemId: itemId,
          kind: 'sale',
          quantity: -5,
          sourceId: 'inv-1',
          date: DateTime(2026, 4, 5),
        );
        await writeLegacyMovement(
          id: 'mv-3',
          itemId: itemId,
          kind: 'purchase',
          quantity: 10,
          sourceId: 'bill-2',
          date: DateTime(2026, 4, 6),
        );

        final before = await (db.select(
          db.stockMovements,
        )..where((t) => t.id.equals('mv-1'))).getSingle();
        expect(
          before.unitCost,
          0,
          reason: 'the fixture has to really be un-costed',
        );

        final rewritten = await db
            .itemRepositoryFor(firmId)
            .backfillUnitCosts();
        expect(rewritten, 3);

        final m1 = await (db.select(
          db.stockMovements,
        )..where((t) => t.id.equals('mv-1'))).getSingle();
        final m2 = await (db.select(
          db.stockMovements,
        )..where((t) => t.id.equals('mv-2'))).getSingle();
        final m3 = await (db.select(
          db.stockMovements,
        )..where((t) => t.id.equals('mv-3'))).getSingle();

        expect(m1.unitCost, closeTo(100.0, 0.0001));
        // The sale sits between the two purchases, so it leaves at the first
        // bill's 100.
        expect(m2.unitCost, closeTo(100.0, 0.0001));
        // 1000 + 3000 = 4000 over 20 = 200.
        expect(m3.unitCost, closeTo(300.0, 0.0001));
      },
    );

    test('running it twice changes nothing the second time', () async {
      final itemId = (await db.itemRepositoryFor(firmId).create(name: 'Widget'))
          .id;
      await writeBill(
        id: 'bill-1',
        lines: [(id: 'bl-1', itemId: itemId, qty: 10, taxable: 1000)],
      );
      await writeLegacyMovement(
        id: 'mv-1',
        itemId: itemId,
        kind: 'purchase',
        quantity: 10,
        sourceId: 'bill-1',
        date: DateTime(2026, 4, 1),
      );

      final repo = db.itemRepositoryFor(firmId);
      expect(await repo.backfillUnitCosts(), 1);
      // Idempotent: a second pass rewrites nothing, so a bug fix can re-run it
      // without a marker row to clear.
      expect(await repo.backfillUnitCosts(), 0);
    });

    test(
      'two lines of the same item on one bill are matched in order',
      () async {
        final itemId =
            (await db.itemRepositoryFor(firmId).create(name: 'Widget')).id;
        // A bill may legitimately carry the same item twice at different rates.
        // Matching by item alone would price both movements off whichever line
        // came first, and the average would be wrong for the rest of time.
        await writeBill(
          id: 'bill-1',
          lines: [
            (id: 'bl-1', itemId: itemId, qty: 1, taxable: 10),
            (id: 'bl-2', itemId: itemId, qty: 1, taxable: 1000),
          ],
        );
        await writeLegacyMovement(
          id: 'mv-1',
          itemId: itemId,
          kind: 'purchase',
          quantity: 1,
          sourceId: 'bill-1',
          date: DateTime(2026, 4, 1, 10),
        );
        await writeLegacyMovement(
          id: 'mv-2',
          itemId: itemId,
          kind: 'purchase',
          quantity: 1,
          sourceId: 'bill-1',
          date: DateTime(2026, 4, 1, 11),
        );

        await db.itemRepositoryFor(firmId).backfillUnitCosts();

        final m1 = await (db.select(
          db.stockMovements,
        )..where((t) => t.id.equals('mv-1'))).getSingle();
        final m2 = await (db.select(
          db.stockMovements,
        )..where((t) => t.id.equals('mv-2'))).getSingle();
        expect(m1.unitCost, closeTo(10.0, 0.0001));
        expect(m2.unitCost, closeTo(1000.0, 0.0001));
      },
    );

    test('a movement that names its line is priced off that line, not off its '
        'position in the bill', () async {
      final itemId = (await db.itemRepositoryFor(firmId).create(name: 'Widget'))
          .id;
      await writeBill(
        id: 'bill-1',
        lines: [
          (id: 'bl-1', itemId: itemId, qty: 1, taxable: 10),
          (id: 'bl-2', itemId: itemId, qty: 1, taxable: 1000),
        ],
      );
      // The expensive line was entered second and posted first. Ordering by
      // position would price this at 10.
      await writeMovement(
        id: 'mv-1',
        itemId: itemId,
        kind: 'purchase',
        quantity: 1,
        sourceId: 'bill-1',
        sourceLineId: 'bl-2',
        date: DateTime(2026, 4, 1, 10),
      );
      await writeMovement(
        id: 'mv-2',
        itemId: itemId,
        kind: 'purchase',
        quantity: 1,
        sourceId: 'bill-1',
        sourceLineId: 'bl-1',
        date: DateTime(2026, 4, 1, 11),
      );

      await db.itemRepositoryFor(firmId).backfillUnitCosts();

      final m1 = await (db.select(
        db.stockMovements,
      )..where((t) => t.id.equals('mv-1'))).getSingle();
      final m2 = await (db.select(
        db.stockMovements,
      )..where((t) => t.id.equals('mv-2'))).getSingle();
      expect(m1.unitCost, closeTo(1000.0, 0.0001));
      expect(m2.unitCost, closeTo(10.0, 0.0001));
    });

    test(
      'an item with no bills at all is left at zero rather than guessed',
      () async {
        // An opening balance has no document behind it. Valuing it from today's
        // purchase price would be inventing history.
        final itemId =
            (await db
                    .itemRepositoryFor(firmId)
                    .create(name: 'Widget', purchasePrice: 99))
                .id;

        await writeLegacyMovement(
          id: 'mv-1',
          itemId: itemId,
          kind: 'opening',
          quantity: 10,
          sourceId: 'opening_balance',
          date: DateTime(2026, 4, 1),
        );

        await db.itemRepositoryFor(firmId).backfillUnitCosts();

        final m1 = await (db.select(
          db.stockMovements,
        )..where((t) => t.id.equals('mv-1'))).getSingle();
        expect(m1.unitCost, 0);
      },
    );
  });

  group('the v11 upgrade', () {
    // Built by rolling a real v11 database *back*: drop what v11 added and set
    // user_version to 10, then reopen. That gives a file whose rows really do
    // predate the columns, which is the only honest way to test that the
    // migration keeps them.
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('atria_v11_migration');
      file = File('${dir.path}/books.db');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('rows survive and pick up the new defaults', () async {
      final first = AppDatabase.test(NativeDatabase(file));
      final firm = await first.firmRepository.create(name: 'Alpha Traders');
      final firmId = firm.id;
      final item = await first
          .itemRepositoryFor(firmId)
          .create(name: 'Widget', purchasePrice: 40);
      await first
          .into(first.stockMovements)
          .insert(
            StockMovementsCompanion.insert(
              id: 'mv-1',
              firmId: firmId,
              itemId: item.id,
              kind: 'purchase',
              quantity: 5,
              source: 'purchase_bills',
              date: DateTime(2026, 4, 1),
            ),
          );
      await first
          .into(first.parties)
          .insert(
            PartiesCompanion.insert(
              id: 'party-1',
              firmId: firmId,
              name: 'Beti Foods',
              type: 'customer',
            ),
          );

      await SchemaRollback.costingV11(first);
      await SchemaRollback.setVersion(first, 10);
      await first.close();

      final upgraded = AppDatabase.test(NativeDatabase(file));
      addTearDown(upgraded.close);

      expect(upgraded.schemaVersion, 11);

      final upgradedItem = await (upgraded.select(
        upgraded.items,
      )..where((t) => t.id.equals(item.id))).getSingle();
      expect(upgradedItem.name, 'Widget', reason: 'the row must survive');
      expect(
        upgradedItem.costingMethod,
        'moving_average',
        reason: 'an upgraded item must cost the way a new one does',
      );
      expect(upgradedItem.defaultGodownId, isNull);

      final movement = await upgraded
          .select(upgraded.stockMovements)
          .getSingle();
      expect(movement.quantity, 5);
      expect(movement.unitCost, 0);
      expect(movement.sourceLineId, isNull);
      expect(movement.godownId, isNull);

      final party = await (upgraded.select(
        upgraded.parties,
      )..where((t) => t.id.equals('party-1'))).getSingle();
      expect(party.name, 'Beti Foods');
      expect(
        party.categoryId,
        isNull,
        reason: 'a category must not be invented for an existing party',
      );

      // The godowns table exists after the upgrade and starts empty, rather
      // than not existing at all and failing every query that names it.
      expect(await upgraded.select(upgraded.godowns).get(), isEmpty);

      // …and carries its index. `createAll` skips a table that already exists
      // and so never applies a `@TableIndex` to an upgraded database; only an
      // explicit `createIndex` does. Without this the firm list reads
      // correctly on a fresh install and does a full scan on every upgraded
      // one — which is the kind of thing that only shows up on the one device
      // with three years of history.
      final indexes = await upgraded
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND tbl_name = 'godowns'",
          )
          .get();
      expect(
        indexes.map((i) => i.read<String>('name')),
        contains('idx_godowns_firm'),
      );
    });
  });
}
