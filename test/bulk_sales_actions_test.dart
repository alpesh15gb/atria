import 'dart:io';

import 'package:atria/core/bulk/bulk_sales_actions.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/services/csv_export.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bulk delete and undo, against a real database.
///
/// The property under test is the one a shop actually depends on: the undo
/// restores what was deleted, and nothing else. A bulk delete that reports the
/// requested count rather than the achieved one would offer an undo covering
/// documents still sitting live in the books, and restoring those can collide
/// with the document number of a real one.
void main() {
  late AppDatabase db;
  late Directory root;
  late BulkSalesActions actions;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('apexbooks_bulk');
    CsvExport.setBaseDirectory(Future.value(root));
    actions = BulkSalesActions(
      sales: db.salesRepositoryFor('f1'),
      firmId: 'f1',
      exportBaseDirectory: () async => root,
    );
    await db
        .into(db.firms)
        .insert(FirmsCompanion.insert(id: 'f1', name: 'Alpha Traders'));
  });

  tearDown(() async {
    await db.close();
    CsvExport.setBaseDirectory(null);
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<SalesInvoiceEntity> seedInvoice(String id, {double total = 100}) => db
      .into(db.salesInvoices)
      .insertReturning(
        SalesInvoicesCompanion.insert(
          id: id,
          firmId: 'f1',
          number: id.toUpperCase(),
          invoiceDate: DateTime(2026, 4, 1),
          partyName: const Value('Beti Foods'),
          grandTotal: Value(total),
          balanceDue: Value(total),
        ),
      );

  Future<bool> isDeleted(String id) async {
    final row = await (db.select(
      db.salesInvoices,
    )..where((t) => t.id.equals(id))).getSingle();
    return row.isDeleted;
  }

  group('bulk delete', () {
    test('every selected invoice is soft-deleted', () async {
      await seedInvoice('inv-a');
      await seedInvoice('inv-b');

      final outcome = await actions.delete(['inv-a', 'inv-b']);

      expect(outcome.isCompleteSuccess, isTrue);
      expect(outcome.deleted, 2);
      expect(await isDeleted('inv-a'), isTrue);
      expect(await isDeleted('inv-b'), isTrue);
    });

    test('an unselected invoice is left alone', () async {
      await seedInvoice('inv-a');
      await seedInvoice('inv-b');

      await actions.delete(['inv-a']);

      expect(await isDeleted('inv-b'), isFalse);
    });

    test('the invoice is not destroyed, only flagged', () async {
      // Soft delete is what makes the undo below possible at all. If this ever
      // becomes a hard delete, the whole undo affordance is a lie.
      await seedInvoice('inv-a');
      await actions.delete(['inv-a']);

      final rows = await db.select(db.salesInvoices).get();
      expect(rows, hasLength(1));
      expect(rows.single.number, 'INV-A');
    });

    test('undo restores exactly what was deleted', () async {
      await seedInvoice('inv-a');
      await seedInvoice('inv-b');

      final outcome = await actions.delete(['inv-a', 'inv-b']);
      final undone = await actions.undoDelete(outcome.deletedIds);

      expect(undone.isCompleteSuccess, isTrue);
      expect(await isDeleted('inv-a'), isFalse);
      expect(await isDeleted('inv-b'), isFalse);
    });

    test('undo does not touch a document that was never deleted', () async {
      await seedInvoice('inv-a');
      await seedInvoice('inv-b');
      await actions.delete(['inv-a']);

      // Restoring inv-b, which was never deleted, must be a no-op rather than
      // writing to a row the operator did not ask about.
      await actions.undoDelete({'inv-a', 'inv-b'});
      await actions.undoDelete({'inv-b'});

      expect(await isDeleted('inv-b'), isFalse);
    });

    test('a failed delete is reported and excluded from the undo', () async {
      await seedInvoice('inv-a');
      // No such row: softDelete throws, and the batch must survive it.
      final outcome = await actions.delete(['inv-a', 'does-not-exist']);

      expect(outcome.deleted, 1);
      expect(outcome.failed, 1);
      expect(outcome.isCompleteSuccess, isFalse);
      expect(outcome.deletedIds, {'inv-a'});
      expect(outcome.deletedIds.contains('does-not-exist'), isFalse);
    });

    test('undo after a partial failure restores the ones that went', () async {
      await seedInvoice('inv-a');
      await seedInvoice('inv-b');

      final outcome = await actions.delete(['inv-a', 'does-not-exist']);
      final undone = await actions.undoDelete(outcome.deletedIds);

      expect(undone.deleted, 1);
      expect(await isDeleted('inv-a'), isFalse);
    });

    test('deleting nothing reports nothing', () async {
      final outcome = await actions.delete([]);
      expect(outcome.requested, 0);
      expect(outcome.deleted, 0);
      expect(outcome.isCompleteSuccess, isTrue);
    });
  });

  group('bulk CSV', () {
    test('holds only the selected invoices', () async {
      await seedInvoice('inv-a');
      await seedInvoice('inv-b');

      final file = await actions.csv({'inv-a'});
      final raw = await file.readAsString();

      expect(raw, contains('INV-A'));
      expect(raw.contains('INV-B'), isFalse);
    });

    test('an empty selection produces a header and no rows', () async {
      await seedInvoice('inv-a');

      final file = await actions.csv({});
      final raw = await file.readAsString();

      expect(raw, contains('Grand Total'));
      expect(raw.contains('INV-A'), isFalse);
    });
  });

  group('bulk PDF', () {
    test('one PDF per selected invoice, named for the document', () async {
      final firm = await (db.select(
        db.firms,
      )..where((f) => f.id.equals('f1'))).getSingle();
      await seedInvoice('inv-a');
      await seedInvoice('inv-b');

      final result = await actions.pdfs(['inv-a', 'inv-b'], firm);

      expect(result.printed, 2);
      expect(result.isCompleteSuccess, isTrue);
      for (final file in result.files.values) {
        expect(file.existsSync(), isTrue);
        expect(file.path, endsWith('.pdf'));
        expect(await file.length(), greaterThan(0));
      }
    });

    test(
      'an invoice that vanished is reported, not skipped silently',
      () async {
        final firm = await (db.select(
          db.firms,
        )..where((f) => f.id.equals('f1'))).getSingle();
        await seedInvoice('inv-a');

        final result = await actions.pdfs(['inv-a', 'ghost'], firm);

        expect(result.printed, 1);
        expect(result.failed, 1);
        expect(result.isCompleteSuccess, isFalse);
        // The survivor keeps its own identity — no index drift.
        expect(result.files.keys, {'inv-a'});
      },
    );
  });

  group('BulkPdfShare', () {
    test('shares every written path in one go', () async {
      final a = File('${root.path}/a.pdf')..writeAsBytesSync([1]);
      final b = File('${root.path}/b.pdf')..writeAsBytesSync([2]);
      List<String>? shared;

      await BulkPdfShare(shareFiles: (paths, {subject}) async => shared = paths)
          .share(BulkPdfResult(files: {'x': a, 'y': b}, failures: const {}));

      expect(shared, [a.path, b.path]);
    });

    test('shares nothing when nothing was printed', () async {
      var called = false;
      await BulkPdfShare(shareFiles: (paths, {subject}) async => called = true)
          .share(const BulkPdfResult(files: {}, failures: {}));

      expect(
        called,
        isFalse,
        reason: 'an empty share sheet on Android is a dead end',
      );
    });
  });
}
