import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/audit_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cover for period locking (books_locked_upto enforcement in the sales
/// repository) and the append-only audit trail.
void main() {
  late AppDatabase db;
  late String firmId;
  late SettingsRepository settings;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(name: 'Lock Test Co');
    firmId = firm.id;
    settings = db.settingsRepository;
  });

  tearDown(() => db.close());

  SalesDraft draft(String id, String number, DateTime date) => SalesDraft(
        id: id,
        number: number,
        docType: 'invoice',
        invoiceDate: date,
        lines: const [],
      );

  test('saving into a locked period throws; after unlock it succeeds',
      () async {
    // April is locked.
    await settings.set(
        PeriodLock.kBooksLockedUpto, DateTime(2026, 4, 30).toIso8601String(),
        firmId: firmId);

    expect(
      () => db.salesRepositoryFor(firmId).save(
            draft('a1', 'INV-1', DateTime(2026, 4, 12)),
          ),
      throwsA(isA<Exception>()),
      reason: 'a document dated INSIDE the lock must be refused',
    );

    // A document dated after the lock is fine.
    await db.salesRepositoryFor(firmId).save(
          draft('a2', 'INV-2', DateTime(2026, 5, 12)),
        );

    // Unlocking restores access to April.
    await settings.remove(PeriodLock.kBooksLockedUpto, firmId: firmId);
    await db.salesRepositoryFor(firmId).save(
          draft('a3', 'INV-3', DateTime(2026, 4, 20)),
        );
  });

  test('soft delete + restore round-trips through the document recycle bin',
      () async {
    final sales = db.salesRepositoryFor(firmId);
    await sales.save(draft('d1', 'INV-DEL', DateTime(2026, 3, 2)));

    await sales.softDelete('d1');
    final deleted = await sales.watchDeleted().first;
    expect(deleted, hasLength(1));
    expect(deleted.single.isDeleted, isTrue);

    await sales.restore('d1');
    final after = await sales.getById('d1');
    expect(after, isNotNull);
    expect(after!.isDeleted, isFalse);
  });

  test('audit trail records create/delete/restore in order', () async {
    final sales = db.salesRepositoryFor(firmId);
    await sales.save(draft('aud1', 'INV-AUD', DateTime(2026, 3, 3)));
    await sales.softDelete('aud1');
    await sales.restore('aud1');

    final logs = await db.auditRepository.list(firmId: firmId);
    final summaries = logs.map((l) => '${l.action}:${l.entity}').toList();
    expect(summaries, containsAll(<String>[
      'delete:sales_invoices',
      'restore:sales_invoices',
    ]));
    // Newest first.
    expect(summaries.first, 'restore:sales_invoices');
  });
}
