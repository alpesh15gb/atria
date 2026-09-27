import 'package:atria/core/constants/payment_modes.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cover for the features added in the "what's missing" pass: expense/income
/// editing, quotation → invoice conversion status, and stock adjustments.
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

  group('expense editing', () {
    test('update persists field changes and clears optional fields', () async {
      final repo = db.expenseRepositoryFor(firmId);
      final created = await repo.create(
        type: 'expense',
        number: 'EXP-1',
        category: 'rent',
        amount: 12000,
        date: DateTime(2026, 9, 1),
        mode: PaymentMode.upi.id,
        vendorName: 'Landlord',
        notes: 'September rent',
      );

      final edited = created.copyWith(
        amount: 12500,
        category: 'utilities',
        // Value(...) wrappers let the editor clear optional fields to NULL.
        vendorName: const Value(null),
        notes: const Value(null),
      );
      final saved = await repo.update(edited);

      expect(saved.amount, 12500);
      expect(saved.category, 'utilities');
      expect(saved.vendorName, isNull, reason: 'clearing a field writes NULL');
      expect(saved.notes, isNull);
      expect(saved.number, 'EXP-1', reason: 'the number must never change');

      final reread = await repo.getById(created.id);
      expect(reread!.amount, 12500);
      expect(reread.vendorName, isNull);
    });

    test('income and expense rows stay separate types after an edit',
        () async {
      final repo = db.expenseRepositoryFor(firmId);
      final income = await repo.create(
        type: 'income',
        number: 'INC-1',
        category: 'interest',
        amount: 500,
        date: DateTime(2026, 9, 2),
      );
      final updated = await repo.update(income.copyWith(amount: 750));
      expect(updated.type, 'income');

      final incomes = await repo.list(type: 'income');
      expect(incomes.single.amount, 750);
      expect(await repo.list(type: 'expense'), isEmpty);
    });
  });

  group('quotation → invoice conversion', () {
    test('markConverted flags the source and is idempotent-safe to re-call',
        () async {
      final sales = db.salesRepositoryFor(firmId);
      final quote = await sales.save(SalesDraft(
        id: 'q1',
        number: 'QT-1',
        docType: 'quotation',
        invoiceDate: DateTime(2026, 9, 20),
        lines: [
          SalesLineDraft(
            id: 'l1',
            name: 'Wall putty 40kg',
            quantity: Decimal.parse('5'),
            unit: 'bags',
            rate: Decimal.parse('400'),
            gstRate: 18,
          ),
        ],
      ));

      await sales.markConverted(quote.id);
      final converted = await sales.getById(quote.id);
      expect(converted!.status, 'converted');

      // A second call must not throw — the UI hides the action, but a stale
      // double-tap before the rebuild would still land here.
      await sales.markConverted(quote.id);
      expect((await sales.getById(quote.id))!.status, 'converted');
    });

    test('a converted quotation can still be edited without losing status '
        '(edit does not resurrect the convert action on its own)', () async {
      final sales = db.salesRepositoryFor(firmId);
      await sales.save(SalesDraft(
        id: 'q2',
        number: 'QT-2',
        docType: 'quotation',
        invoiceDate: DateTime(2026, 9, 20),
        lines: [
          SalesLineDraft(
            // Line ids are globally unique, not per-document — reusing 'l1'
            // across two documents trips the UNIQUE constraint.
            id: 'ql1',
            name: 'Primer',
            quantity: Decimal.one,
            unit: 'ltr',
            rate: Decimal.parse('250'),
            gstRate: 18,
          ),
        ],
      ));
      await sales.markConverted('q2');

      // The convert flow the editor performs: save the NEW invoice, then
      // mark the source. The source stays converted; the new doc is an
      // invoice with a fresh number.
      await sales.save(SalesDraft(
        id: 'inv1',
        number: 'INV-1',
        docType: 'invoice',
        invoiceDate: DateTime(2026, 9, 26),
        dueDate: DateTime(2026, 10, 10),
        lines: [
          SalesLineDraft(
            id: 'il1',
            name: 'Primer',
            quantity: Decimal.one,
            unit: 'ltr',
            rate: Decimal.parse('250'),
            gstRate: 18,
          ),
        ],
      ));
      await sales.markConverted('q2');

      final invoice = await sales.getById('inv1');
      expect(invoice!.docType, 'invoice');
      expect(invoice.number, 'INV-1');
      expect(invoice.status, isNot('converted'),
          reason: 'the generated invoice must not inherit the converted flag');
      expect((await sales.getById('q2'))!.status, 'converted');
    });
  });

  group('stock adjustment', () {
    test('applyStockEffect(kind: adjustment) updates stock and posts a '
        'movement with the delta', () async {
      final items = db.itemRepositoryFor(firmId);
      final item = await items.create(
        name: 'Cement OPC 50kg',
        unit: 'bags',
        salePrice: 380,
        purchasePrice: 340,
        gstRate: 28,
        openingStock: 100,
      );

      // Counted 96 → delta −4 (damage/write-off).
      await items.applyStockEffect(
        itemId: item.id,
        quantity: -4,
        kind: 'adjustment',
        source: 'adjustment',
        notes: 'damaged bags',
      );

      final after = await items.getById(item.id);
      expect(after!.currentStock, 96);

      final movements = await items.movements(item.id);
      final adjustment = movements.firstWhere((m) => m.kind == 'adjustment');
      expect(adjustment.quantity, -4);
      expect(adjustment.balanceAfter, 96);
      expect(adjustment.source, 'adjustment');
      expect(adjustment.notes, 'damaged bags');
    });

    test('a positive adjustment adds stock the same way', () async {
      final items = db.itemRepositoryFor(firmId);
      final item = await items.create(
        name: 'Paint 4L',
        unit: 'pcs',
        salePrice: 900,
        purchasePrice: 760,
        gstRate: 18,
        openingStock: 10,
      );

      await items.applyStockEffect(
        itemId: item.id,
        quantity: 2.5,
        kind: 'adjustment',
        source: 'adjustment',
      );

      final after = await items.getById(item.id);
      expect(after!.currentStock, 12.5);
      final movements = await items.movements(item.id);
      expect(movements.any((m) => m.kind == 'adjustment' && m.quantity == 2.5),
          isTrue);
    });
  });
}
