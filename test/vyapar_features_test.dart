import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/firm_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/engine/document_numbering.dart';
import 'package:atria/core/services/csv_export.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cover for the Vyapar-inspired feature pass: soft delete + recycle bin,
/// returns suites (credit/debit notes), delivery notes, the new document
/// series, and CSV escaping.
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

  group('recycle bin (soft delete)', () {
    test('party delete hides it from lists and restore brings it back',
        () async {
      final repo = db.partyRepositoryFor(firmId);
      final party = await repo.create(name: 'Ramesh Kirana', type: 'customer');

      await repo.delete(party.id);

      // Hidden from the live list, still openable by id.
      expect(await repo.all(), isEmpty);
      expect((await repo.getById(party.id))!.isDeleted, isTrue);

      final bin = await repo.watchDeleted().first;
      expect(bin.single.id, party.id);

      await repo.restore(party.id);
      expect((await repo.all()).single.id, party.id);
      expect((await repo.getById(party.id))!.deletedAt, isNull);
    });

    test('item delete keeps stock history intact and restore re-lists',
        () async {
      final items = db.itemRepositoryFor(firmId);
      final item = await items.create(
        name: 'Cement 50kg',
        unit: 'bags',
        salePrice: 380,
        purchasePrice: 340,
        openingStock: 10,
      );
      await items.applyStockEffect(
        itemId: item.id,
        quantity: -2,
        kind: 'sale',
        source: 'sales_invoices',
      );

      await items.delete(item.id);
      expect(await items.all(), isEmpty);

      // History survives a soft delete — the ledger must never lose rows.
      final movements = await items.movements(item.id);
      expect(movements.length, 2, reason: 'opening + sale movements remain');

      // Permanent delete is refused while history exists.
      await expectLater(items.deleteForever(item.id), throwsStateError);

      await items.restore(item.id);
      expect((await items.all()).single.currentStock, 8);
    });

    test('party deleteForever refuses when documents reference the party',
        () async {
      final parties = db.partyRepositoryFor(firmId);
      final sales = db.salesRepositoryFor(firmId);
      final party =
          await parties.create(name: 'Royal Interiors', type: 'customer');

      await sales.save(SalesDraft(
        id: 'inv1',
        number: 'INV-1',
        docType: 'invoice',
        invoiceDate: DateTime(2026, 9, 26),
        partyId: party.id,
        partyName: party.name,
        lines: [
          SalesLineDraft(
            id: 'il1',
            name: 'Service',
            quantity: Decimal.one,
            unit: 'nos',
            rate: Decimal.parse('1000'),
            gstRate: 18,
          ),
        ],
      ));

      await parties.delete(party.id);
      await expectLater(parties.deleteForever(party.id), throwsStateError);
      // Still in the bin, recoverable.
      expect((await parties.watchDeleted().first).single.id, party.id);
    });
  });

  group('returns suite', () {
    test('credit note restores stock (positive movement) without balance',
        () async {
      final items = db.itemRepositoryFor(firmId);
      final sales = db.salesRepositoryFor(firmId);
      final item = await items.create(
        name: 'Paint 4L',
        unit: 'pcs',
        salePrice: 900,
        purchasePrice: 760,
        openingStock: 20,
      );

      await sales.save(SalesDraft(
        id: 'inv1',
        number: 'INV-1',
        docType: 'invoice',
        invoiceDate: DateTime(2026, 9, 20),
        lines: [
          SalesLineDraft(
            id: 'il1',
            itemId: item.id,
            name: 'Paint 4L',
            quantity: Decimal.parse('5'),
            unit: 'pcs',
            rate: Decimal.parse('900'),
            gstRate: 18,
          ),
        ],
      ));
      expect((await items.getById(item.id))!.currentStock, 15);

      // The customer returns 2 units: the credit note posts a positive
      // sale_return movement and carries no receivable of its own.
      await sales.save(
        SalesDraft(
          id: 'cn1',
          number: 'CN-1',
          docType: 'credit_note',
          invoiceDate: DateTime(2026, 9, 26),
          lines: [
            SalesLineDraft(
              id: 'cl1',
              itemId: item.id,
              name: 'Paint 4L',
              quantity: Decimal.parse('2'),
              unit: 'pcs',
              rate: Decimal.parse('900'),
              gstRate: 18,
            ),
          ],
        ),
        affectStock: true,
      );

      expect((await items.getById(item.id))!.currentStock, 17);
      final cn = await sales.getById('cn1');
      expect(cn!.docType, 'credit_note');
      expect(cn.balanceDue, 0,
          reason: 'a credit note is not a receivable of its own');
      final movements = await items.movements(item.id);
      expect(
        movements.any((m) => m.kind == 'sale_return' && m.quantity == 2.0),
        isTrue,
      );
    });

    test('delivery note does not touch stock — the invoice does', () async {
      final items = db.itemRepositoryFor(firmId);
      final sales = db.salesRepositoryFor(firmId);
      final item = await items.create(
        name: 'Primer',
        unit: 'ltr',
        salePrice: 250,
        purchasePrice: 200,
        openingStock: 50,
      );

      await sales.save(
        SalesDraft(
          id: 'ch1',
          number: 'CH-1',
          docType: 'delivery_note',
          invoiceDate: DateTime(2026, 9, 26),
          lines: [
            SalesLineDraft(
              id: 'dl1',
              itemId: item.id,
              name: 'Primer',
              quantity: Decimal.parse('10'),
              unit: 'ltr',
              rate: Decimal.parse('250'),
              gstRate: 18,
            ),
          ],
        ),
        affectStock: true, // the UI always passes true; repo must guard
      );

      expect((await items.getById(item.id))!.currentStock, 50,
          reason: 'goods-in-transit are still ours until invoiced');
      expect((await sales.getById('ch1'))!.docType, 'delivery_note');
    });

    test('new document series number independently', () async {
      final firmRepo = db.firmRepository;
      final firm = (await firmRepo.all()).single;

      final cn1 = await firmRepo.nextNumber(firm, DocSequence.creditNote);
      final cn2 = await firmRepo.nextNumber(firm, DocSequence.creditNote);
      final dn1 = await firmRepo.nextNumber(firm, DocSequence.debitNote);
      final ch1 = await firmRepo.nextNumber(firm, DocSequence.deliveryNote);

      // The default numbering style is financial-year: PREFIX/FY/seq.
      final fy = FinancialYear.forDate(DateTime.now()).shortLabel;
      expect(cn1, 'CN/$fy/001');
      expect(cn2, 'CN/$fy/002');
      expect(dn1, 'DN/$fy/001');
      expect(ch1, 'CH/$fy/001');
      // The invoice series is untouched by the new ones.
      final inv1 = await firmRepo.nextNumber(firm, DocSequence.invoice);
      expect(inv1, 'INV/$fy/001');
    });

    test('nextNumber completes when the FY row is stale (regression: deadlock)',
        () async {
      // A fresh firm has sequenceFy NULL while the numbering format embeds
      // the current FY. The guarded UPDATE used to compare against the
      // RESET (post-FY-change) values instead of the stored ones, matched
      // nothing and spun forever — every first nextNumber call hung.
      final firmRepo = db.firmRepository;
      final firm = (await firmRepo.all()).single;
      expect(firm.sequenceFy, isNull);

      // Must complete (test timeout would fail it) and reset to the new FY.
      final inv1 = await firmRepo
          .nextNumber(firm, DocSequence.invoice)
          .timeout(const Duration(seconds: 10));
      final fy = FinancialYear.forDate(DateTime.now()).shortLabel;
      expect(inv1, 'INV/$fy/001');

      final updated = (await firmRepo.all()).single;
      expect(updated.sequenceFy, isNotNull);
      expect(updated.invoiceSequence, 1);

      // And the second mint continues the series through the same path.
      final inv2 = await firmRepo
          .nextNumber(updated, DocSequence.invoice)
          .timeout(const Duration(seconds: 10));
      expect(inv2, 'INV/$fy/002');
    });
  });

  group('CSV export', () {
    test('escaping wraps fields with commas, quotes and newlines', () {
      expect(CsvExport.esc('plain'), 'plain');
      expect(CsvExport.esc('has,comma'), '"has,comma"');
      expect(CsvExport.esc('say "hi"'), '"say ""hi"""');
      expect(CsvExport.esc('two\nlines'), '"two\nlines"');
      expect(CsvExport.esc(null), '');
      expect(CsvExport.row(['a', 'b,c', 'd']), 'a,"b,c",d');
    });

    test('export produces files with header + data rows', () async {
      // Point the exporter at a temp dir — the platform channel behind
      // getApplicationDocumentsDirectory has no handler under flutter_test.
      final tmp = await Directory.systemTemp.createTemp('atria_csv_test');
      CsvExport.setBaseDirectory(Future.value(tmp));
      addTearDown(() => CsvExport.setBaseDirectory(null));

      final repo = db.partyRepositoryFor(firmId);
      await repo.create(name: 'Ramesh Kirana', type: 'customer');
      await repo.create(
          name: 'Singh, Sons & Co.', type: 'supplier', phone: '9876543210');

      final export = CsvExport(db, firmId);
      final file = await export.parties();
      final raw = await file.readAsBytes();
      // The BOM keeps Excel on UTF-8 for Indian names: EF BB BF.
      // (readAsString would strip it, so assert on the raw bytes.)
      expect(raw[0], 0xEF);
      expect(raw[1], 0xBB);
      expect(raw[2], 0xBF);
      final content = await file.readAsString();
      final lines = content.replaceAll('\r\n', '\n').trim().split('\n');
      expect(lines.length, 3, reason: 'header + 2 parties');
      expect(lines[1], contains('Ramesh Kirana'));
      // The comma in the name must be quoted, not split into a new column.
      expect(lines[2], contains('"Singh, Sons & Co."'));
    });
  });
}
