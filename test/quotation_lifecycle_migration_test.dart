import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/domain/document_status.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/schema_rollback.dart';

/// The v8 -> v9 upgrade, for the quotation lifecycle.
///
/// Built by rolling a real v9 database *back*: drop the two new columns and
/// set user_version to 8, then reopen. That gives a file whose rows really do
/// predate the columns, which is the only honest way to test that the
/// migration keeps them.
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('atria_v8_migration');
    file = File('${dir.path}/books.db');
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<SalesInvoiceEntity> quotation(
    AppDatabase db,
    String firmId,
    String id, {
    String docType = 'quotation',
  }) async {
    final repo = db.salesRepositoryFor(firmId);
    await repo.save(
      SalesDraft(
        id: id,
        number: id.toUpperCase(),
        docType: docType,
        invoiceDate: DateTime(2026, 9, 20),
        lines: [
          SalesLineDraft(
            id: 'l-$id',
            name: 'Consulting',
            quantity: Decimal.one,
            unit: 'svc',
            rate: Decimal.fromInt(1500),
            gstRate: 18,
          ),
        ],
      ),
    );
    return (await repo.getById(id))!;
  }

  test('existing rows survive and pick up two nulls', () async {
    // 1. Build a current database with a firm and a few documents in it.
    final first = AppDatabase.test(NativeDatabase(file));
    final firm = await first.firmRepository.create(name: 'Alpha Traders');
    final firmId = firm.id;
    await quotation(first, firmId, 'q-open');
    final legacyConverted = await quotation(first, firmId, 'q-legacy');
    await quotation(first, firmId, 'inv-1', docType: 'invoice');

    // A quotation converted the old way: the flag lives in `status`, and the
    // invoice it became was never recorded anywhere. This is the shape that
    // actually exists on real user databases.
    await first
        .update(first.salesInvoices)
        .replace(
          legacyConverted.copyWith(status: DocumentStatus.legacyConvertedValue),
        );

    // 2. Roll it back to what a v8 file looked like. The v10 and v11 columns go
    //    too: the chain runs from 8 all the way to current, so leaving them in
    //    place makes those steps fail on a duplicate column. Every migration
    //    test in this repo has to keep this list current — a test that only
    //    rolls back its *own* version stops testing anything the moment a
    //    later migration lands.
    await first.customStatement(
      'ALTER TABLE sales_invoices DROP COLUMN converted_to_invoice_id',
    );
    await first.customStatement(
      'ALTER TABLE sales_invoices DROP COLUMN converted_at',
    );
    await first.customStatement(
      'ALTER TABLE firm_members DROP COLUMN pin_hash',
    );
    await first.customStatement(
      'ALTER TABLE firm_members DROP COLUMN pin_salt',
    );
    await first.customStatement(
      'ALTER TABLE firm_members DROP COLUMN is_active',
    );
    await SchemaRollback.costingV11(first);
    await SchemaRollback.setVersion(first, 8);
    await first.close();

    // 3. Reopen: this runs the v8 -> v9, v9 -> v10 and v10 -> v11 upgrades.
    final upgraded = AppDatabase.test(NativeDatabase(file));
    addTearDown(upgraded.close);

    final sales = upgraded.salesRepositoryFor(firmId);

    final upgradedOpen = await sales.getById('q-open');
    expect(upgradedOpen, isNotNull, reason: 'the row must survive');
    expect(upgradedOpen!.number, 'Q-OPEN');
    expect(
      upgradedOpen.status,
      'confirmed',
      reason: 'an upgrade must not invent a lifecycle the row did not have',
    );
    expect(upgradedOpen.convertedToInvoiceId, isNull);
    expect(upgradedOpen.convertedAt, isNull);

    final upgradedInvoice = await sales.getById('inv-1');
    expect(upgradedInvoice, isNotNull);
    expect(upgradedInvoice!.docType, 'invoice');

    // The legacy converted row keeps its flag, and still reads as converted.
    // Rewriting it would be *worse*: the invoice it became was never recorded,
    // so there is nothing to migrate it to, and clearing the flag would make a
    // quotation that has genuinely been invoiced look convertible again — a
    // second invoice spawned from the same document.
    final upgradedConverted = await sales.getById('q-legacy');
    expect(upgradedConverted!.status, DocumentStatus.legacyConvertedValue);
    expect(upgradedConverted.convertedToInvoiceId, isNull);
    expect(
      DocumentStatus.of(upgradedConverted.status, 'quotation'),
      DocumentStatus.convertedLegacy,
    );
    expect(
      () => sales.markCancelled('q-legacy'),
      throwsA(isA<StateError>()),
      reason: 'cancelling it would wipe the only record that it was invoiced',
    );

    expect(upgraded.schemaVersion, 11);
  });
}
