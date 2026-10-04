import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/services/csv_export.dart';
import 'package:atria/core/utils/formatters.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Export the selected rows" needs the exporter to actually filter.
///
/// Before this, every `CsvExport` method was whole-table with no filter
/// parameter at all, so the only way to produce a subset file was to export
/// everything and delete the rows you did not want — which for a shop that
/// wants one customer's statements out of four thousand invoices is not a
/// feature. The subtle case is the empty selection: it must produce a
/// header-only file, and never fall through to "no filter means everything".
void main() {
  late AppDatabase db;
  late Directory root;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('apexbooks_csv_filter');
    CsvExport.setBaseDirectory(Future.value(root));
  });

  tearDown(() async {
    await db.close();
    CsvExport.setBaseDirectory(null);
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> seedParty(String id, String name) => db
      .into(db.parties)
      .insert(
        PartiesCompanion.insert(
          id: id,
          firmId: 'f1',
          name: name,
          type: 'customer',
        ),
      );

  /// The data rows of a written CSV — header stripped, blanks dropped.
  Future<List<String>> dataRowsOf(File file) async {
    final raw = await file.readAsString();
    return raw
        .replaceFirst('﻿', '')
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .skip(1)
        .map((line) => line.trim())
        .toList();
  }

  setUpAll(() async {
    // Registered after db exists per-test; this placeholder documents that the
    // firms row must exist for the exports' firm filter to match anything.
  });

  setUp(() async {
    await db
        .into(db.firms)
        .insert(FirmsCompanion.insert(id: 'f1', name: 'Alpha Traders'));
  });

  group('parties export filter', () {
    test('no filter exports the whole table', () async {
      await seedParty('p1', 'Beti Foods');
      await seedParty('p2', 'Chai Corner');

      final rows = await dataRowsOf(await CsvExport(db, 'f1').parties());
      expect(rows, hasLength(2));
    });

    test('a filter exports only the ticked rows', () async {
      await seedParty('p1', 'Beti Foods');
      await seedParty('p2', 'Chai Corner');
      await seedParty('p3', 'Deep Mart');

      final rows = await dataRowsOf(
        await CsvExport(db, 'f1').parties(ids: {'p1', 'p3'}),
      );

      expect(rows, hasLength(2));
      expect(rows.first, startsWith('Beti Foods'));
      expect(rows.last, startsWith('Deep Mart'));
      expect(rows.any((r) => r.contains('Chai Corner')), isFalse);
    });

    test('an empty selection exports a header and no rows', () async {
      // The case that matters most. If empty fell through to "no filter", a
      // user who ticked nothing and pressed Export would be handed a file with
      // every party in the firm in it.
      await seedParty('p1', 'Beti Foods');
      await seedParty('p2', 'Chai Corner');

      final rows = await dataRowsOf(await CsvExport(db, 'f1').parties(ids: {}));

      expect(rows, isEmpty);
    });

    test('the header is still present in an empty export', () async {
      // A zero-byte or headless file is not a valid CSV; Excel shows an error
      // rather than an empty sheet, which reads as a failed export.
      final raw = await (await CsvExport(db, 'f1').parties(ids: {}))
          .readAsString();
      expect(raw, contains('GSTIN'));
      expect(raw, contains('Opening Balance'));
    });

    test('an id that is not in the table contributes nothing', () async {
      await seedParty('p1', 'Beti Foods');

      final rows = await dataRowsOf(
        await CsvExport(db, 'f1').parties(ids: {'p1', 'ghost'}),
      );
      expect(rows, hasLength(1));
    });

    test('a deleted party is excluded even when explicitly selected', () async {
      await seedParty('p1', 'Beti Foods');
      await seedParty('p2', 'Chai Corner');
      await (db.update(db.parties)..where((t) => t.id.equals('p2'))).write(
        const PartiesCompanion(isDeleted: Value(true)),
      );

      final rows = await dataRowsOf(
        await CsvExport(db, 'f1').parties(ids: {'p1', 'p2'}),
      );

      expect(rows, hasLength(1));
      expect(
        rows.single,
        startsWith('Beti Foods'),
        reason: 'a recycled-bin row must not be exported as live',
      );
    });

    test('another firm\'s party is excluded even when explicitly selected', () async {
      // The id filter must narrow *within* the firm, never replace it. A
      // filter that dropped the firm clause would leak one business's data into
      // another's export.
      await db
          .into(db.firms)
          .insert(FirmsCompanion.insert(id: 'f2', name: 'Beta Stores'));
      await seedParty('p1', 'Beti Foods');
      await db
          .into(db.parties)
          .insert(
            PartiesCompanion.insert(
              id: 'p9',
              firmId: 'f2',
              name: 'Rival Customer',
              type: 'customer',
            ),
          );

      final rows = await dataRowsOf(
        await CsvExport(db, 'f1').parties(ids: {'p1', 'p9'}),
      );

      expect(rows, hasLength(1));
      expect(rows.single, contains('Beti Foods'));
      expect(rows.single.contains('Rival Customer'), isFalse);
    });
  });

  group('items and expenses exports accept the same filter', () {
    test('items are filtered', () async {
      await db
          .into(db.items)
          .insert(
            ItemsCompanion.insert(
              id: 'i1',
              firmId: 'f1',
              name: 'Chai',
              salePrice: const Value(20.0),
            ),
          );
      await db
          .into(db.items)
          .insert(
            ItemsCompanion.insert(
              id: 'i2',
              firmId: 'f1',
              name: 'Samosa',
              salePrice: const Value(30.0),
            ),
          );

      final rows = await dataRowsOf(
        await CsvExport(db, 'f1').items(ids: {'i2'}),
      );
      expect(rows, hasLength(1));
      expect(rows.single, startsWith('Samosa'));
    });

    test('an empty expenses selection exports nothing', () async {
      await db
          .into(db.expenses)
          .insert(
            ExpensesCompanion.insert(
              id: 'e1',
              firmId: 'f1',
              number: 'EXP-1',
              type: const Value('expense'),
              category: 'rent',
              amount: 1000,
              date: DateTime(2026, 4, 1),
            ),
          );

      final rows = await dataRowsOf(
        await CsvExport(db, 'f1').expenses(ids: {}),
      );
      expect(rows, isEmpty);
    });

    test('sales rows are filtered and keep their ordering', () async {
      for (final (id, number, date) in [
        ('s1', 'INV-1', DateTime(2026, 4, 1)),
        ('s2', 'INV-2', DateTime(2026, 4, 5)),
        ('s3', 'INV-3', DateTime(2026, 4, 9)),
      ]) {
        await db
            .into(db.salesInvoices)
            .insert(
              SalesInvoicesCompanion.insert(
                id: id,
                firmId: 'f1',
                number: number,
                invoiceDate: date,
                grandTotal: const Value(100.0),
              ),
            );
      }

      final rows = await dataRowsOf(
        await CsvExport(db, 'f1').sales(ids: {'s1', 's3'}),
      );

      expect(rows, hasLength(2));
      // Newest first — the filter must not disturb the ordering the whole-table
      // export already had.
      expect(rows.first, startsWith(Formatters.date(DateTime(2026, 4, 9))));
    });
  });
}
