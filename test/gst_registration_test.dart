import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:atria/core/engine/gst_engine.dart';
import 'package:atria/core/reports/gst_return_builder.dart';
import 'package:atria/shared/widgets/gst_registration_field.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late String firmId;
  final date = DateTime(2026, 10, 1);
  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firmId = (await db.firmRepository.create(name: 'Non GST shop')).id;
  });
  tearDown(() => db.close());

  SalesDraft sale(String id, {TaxMode mode = TaxMode.exclusive}) => SalesDraft(
    id: id,
    number: id,
    docType: 'invoice',
    invoiceDate: date,
    lines: [
      SalesLineDraft(
        id: '$id-line',
        name: 'Goods',
        quantity: Decimal.one,
        unit: 'pcs',
        rate: Decimal.fromInt(100),
        gstRate: 18,
        cessRate: 1,
        taxMode: mode,
      ),
    ],
  );

  test('non-GST sales cannot collect GST or cess, including inclusive catalogue prices', () async {
    final repo = db.salesRepositoryFor(firmId);
    for (final mode in TaxMode.values) {
      final invoice = await repo.save(sale(mode.name, mode: mode));
      expect(invoice.grandTotal, 100);
      expect(invoice.cgst + invoice.sgst + invoice.igst + invoice.cess, 0);
      final line = (await repo.itemsFor(invoice.id)).single;
      expect(line.gstRate, 0);
      expect(line.cessRate, 0);
      expect(line.total, 100);
    }
  });

  test('registration enables sales tax, and removing registration preserves a historical taxed invoice', () async {
    var firm = (await db.firmRepository.getById(firmId))!;
    firm = await db.firmRepository.update(
      firm.copyWith(gstin: const Value('29ABCDE1234F1Z5')),
    );
    final repo = db.salesRepositoryFor(firmId);
    final taxed = await repo.save(sale('taxed'));
    expect(taxed.grandTotal, 119);
    await db.firmRepository.update(firm.copyWith(gstin: const Value(null)));
    expect((await repo.save(sale('taxed'))).grandTotal, 119);
    expect((await repo.save(sale('new'))).grandTotal, 100);
  });

  test('supplier GST is retained in non-GST purchase cost, stock, backfill and ledger after registration changes', () async {
    final item = await db.itemRepositoryFor(firmId).create(name: 'Stock');
    PurchaseDraft draft(String id) => PurchaseDraft(
      id: id,
      number: id,
      docType: 'bill',
      billDate: date,
      lines: [
        PurchaseLineDraft(
          id: '$id-line',
          itemId: item.id,
          name: 'Stock',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.fromInt(100),
          gstRate: 18,
        ),
      ],
    );
    final repo = db.purchaseRepositoryFor(firmId);
    final bill = await repo.save(draft('non-gst'));
    expect(bill.grandTotal, 118);
    expect(bill.itcEligible, isFalse);
    expect((await db.select(db.stockMovements).get()).single.unitCost, 118);
    await db.itemRepositoryFor(firmId).backfillUnitCosts();
    expect((await db.select(db.stockMovements).get()).single.unitCost, 118);
    final ledger = db.ledgerRepositoryFor(firmId);
    final trial = await ledger.trialBalance(asOf: DateTime(2026, 10, 31));
    expect(trial.totalDebit, trial.totalCredit);
    expect(
      trial.rows
          .where((r) => r.account.code == LedgerCodes.inputGst)
          .fold<double>(0, (sum, row) => sum + row.closing),
      0,
    );
    expect(
      trial.rows
          .singleWhere((r) => r.account.code == LedgerCodes.purchases)
          .closing,
      118,
    );
    final firm = (await db.firmRepository.getById(firmId))!;
    await db.firmRepository.update(
      firm.copyWith(gstin: const Value('29ABCDE1234F1Z5')),
    );
    expect((await repo.save(draft('non-gst'))).itcEligible, isFalse);
    expect((await repo.save(draft('registered'))).itcEligible, isTrue);
    final summary = await db
        .reportRepositoryFor(firmId)
        .gstSummary(from: date, to: DateTime(2026, 10, 31));
    expect(summary.inputTax, Decimal.fromInt(18));
  });

  test(
    'non-GST expense does not create ITC and other income does not collect GST',
    () async {
      final repo = db.expenseRepositoryFor(firmId);
      final expense = await repo.create(
        type: 'expense',
        number: 'E1',
        category: 'rent',
        amount: 118,
        gstAmount: 18,
        date: date,
      );
      expect(expense.gstAmount, 18);
      expect(expense.itcEligible, isFalse);
      final income = await repo.create(
        type: 'income',
        number: 'I1',
        category: 'interest',
        amount: 118,
        gstAmount: 18,
        date: date,
      );
      expect(income.gstAmount, 0);
      expect(
        await db
            .ledgerRepositoryFor(firmId)
            .inputTaxFromExpenses(to: DateTime(2026, 10, 31)),
        0,
      );
      await expectLater(
        GstReturnBuilder(db, firmId).buildGstr1(from: date, to: date),
        throwsStateError,
      );
      await expectLater(
        buildGstr3b(db, firmId, from: date, to: date),
        throwsStateError,
      );
    },
  );

  test('v13 migration adds registration snapshots without losing documents or settings', () async {
    final dir = await Directory.systemTemp.createTemp('atria_gst_v14_');
    final file = File('${dir.path}/books.db');
    final old = AppDatabase.test(NativeDatabase(file));
    await old.firmRepository.create(name: 'Existing books');
    await old.settingsRepository.set(SettingsRepository.kInterfaceScale, '1.3');
    await old.customStatement(
      'ALTER TABLE purchase_bills DROP COLUMN itc_eligible',
    );
    await old.customStatement('ALTER TABLE expenses DROP COLUMN itc_eligible');
    await old.customStatement('PRAGMA user_version = 13');
    await old.close();
    final upgraded = AppDatabase.test(NativeDatabase(file));
    try {
      expect(
        (await upgraded.firmRepository.all()).single.name,
        'Existing books',
      );
      expect(
        await upgraded.settingsRepository.get(
          SettingsRepository.kInterfaceScale,
        ),
        '1.3',
      );
      expect(upgraded.schemaVersion, 14);
      await upgraded
          .customSelect('SELECT itc_eligible FROM purchase_bills')
          .get();
      await upgraded.customSelect('SELECT itc_eligible FROM expenses').get();
    } finally {
      await upgraded.close();
      await dir.delete(recursive: true);
    }
  });

  testWidgets(
    'registration choice hides GSTIN and requires it only for registered businesses',
    (tester) async {
      final controller = TextEditingController();
      final key = GlobalKey<FormState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: key,
              child: GstRegistrationField(
                controller: controller,
                onChanged: () {},
                gstinField: TextFormField(
                  controller: controller,
                  decoration: const InputDecoration(labelText: 'GSTIN'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('GSTIN'), findsNothing);
      expect(key.currentState!.validate(), isTrue);
      await tester.tap(find.byType(DropdownButtonFormField<bool>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GST registered').last);
      await tester.pumpAndSettle();
      expect(find.text('GSTIN'), findsOneWidget);
      expect(key.currentState!.validate(), isFalse);
      controller.text = '29ABCDE1234F1Z5';
      expect(key.currentState!.validate(), isTrue);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
