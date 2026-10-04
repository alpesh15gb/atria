import 'dart:convert';
import 'dart:io';

import 'package:atria/core/api/api_config.dart';
import 'package:atria/core/api/auth_client.dart';
import 'package:atria/core/api/server_session.dart';
import 'package:atria/core/api/sync_client.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:atria/core/state/auth_controller.dart';
import 'package:atria/core/sync/sync_engine.dart';
import 'package:decimal/decimal.dart';
// drift exports its own `isNull`/`isNotNull` expression builders, which collide
// with the matchers of the same name.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The outbox is the only copy of a change that exists on the device, so every
/// way it can be dropped, double-sent or wedged deserves a test: the drain has
/// to send in order, be idempotent, and never mark a change as sent when it was
/// not. A regression here is silent data loss rather than a visible crash, which
/// is exactly the kind of bug a test suite has to hold.
void main() {
  late AppDatabase db;
  late String firmId;
  late HttpServer server;
  late SyncEngine engine;
  late SettingsRepository settings;
  late AuthController auth;

  final requests = <String>[]; // "/v1/firms", "/v1/firms/<id>/changes"
  final bodies = <List<Object?>>[];
  final auths = <String?>[];

  late int pushStatus;
  late String pushBody;

  /// Every `change_id` the fake server has accepted — a stand-in for the
  /// server's `firm_changes.change_id` PRIMARY KEY. A repeat id is dropped,
  /// as `ON CONFLICT DO NOTHING` does, so a test can prove a re-push really
  /// was accepted rather than silently deduplicated.
  final journalIds = <String>{};

  setUp(() async {
    requests.clear();
    bodies.clear();
    auths.clear();
    journalIds.clear();
    pushStatus = 200;
    pushBody = jsonEncode({'received': 1, 'duplicates': 0});

    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Shri Balaji Traders',
      stateCode: '29',
      gstin: '29ABCDE1234F1Z5',
    );
    firmId = firm.id;
    settings = SettingsRepository(db);
    // Creating the firm queues a change of its own. Clearing the outbox here
    // keeps each test about the change it makes; the firm's own change is
    // covered by the same code path as every other entity.
    await db.delete(db.syncQueue).go();

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri.path);
      auths.add(request.headers.value('authorization'));
      final raw = await utf8.decoder.bind(request).join();
      if (raw.trim().isEmpty) {
        bodies.add(const []);
      } else {
        final decoded = jsonDecode(raw);
        bodies.add(
          decoded is Map && decoded['changes'] is List
              ? (decoded['changes'] as List)
              : [decoded],
        );
      }

      // A firm create answers its own shape; the change push answers ours.
      final isFirmCreate = request.uri.path == '/v1/firms';
      if (!isFirmCreate) {
        // Model `ON CONFLICT (change_id) DO NOTHING`: the first change_id
        // wins and a repeat is dropped, exactly as Postgres would. Tests
        // that care about the journal fill this in.
        for (final change in bodies.last) {
          if (change is Map && change['id'] is String) {
            journalIds.add(change['id'] as String);
          }
        }
      }
      request.response
        ..statusCode = isFirmCreate ? 201 : pushStatus
        ..headers.contentType = ContentType.json
        ..write(isFirmCreate
            ? jsonEncode({'firmId': firmId, 'name': 'Shri Balaji Traders'})
            : pushBody);
      await request.response.close();
    });

    await settings.set(
      SettingsRepository.kApiBaseUrl,
      'http://127.0.0.1:${server.port}',
    );
    await settings.setBool(SettingsRepository.kSyncEnabled, true);

    final config = ApiConfig(settings);
    auth = AuthController(ServerSession(settings), AuthClient(config));
    // A live session, written straight into settings: the drain's business is
    // the outbox, not how the token got there.
    await settings.set(SettingsRepository.kUserEmail, 'owner@apexbooks.in');
    await settings.set(SettingsRepository.kAccessToken, 'access-1');
    await settings.set(SettingsRepository.kRefreshToken, 'refresh-1');
    await settings.set(
      SettingsRepository.kAccessTokenExpiresAt,
      DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
    );

    engine = SyncEngine(
      db,
      settings,
      auth,
      SyncClient(config, timeout: const Duration(seconds: 5)),
    );
  });

  tearDown(() async {
    try {
      await server.close(force: true);
    } on Object {
      // already closed by a test
    }
    await db.close();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> addParty(String name) async {
    await db.partyRepositoryFor(firmId).create(name: name);
  }

  test('with sync off nothing is sent and the outbox is untouched', () async {
    await settings.setBool(SettingsRepository.kSyncEnabled, false);
    await addParty('Ravi Kumar');

    final report = await engine.push();

    expect(report.skipped, true);
    expect(report.pending, 1);
    expect(requests, isEmpty);
  });

  test('signed out, the outbox waits rather than being marked sent', () async {
    for (final key in [
      SettingsRepository.kAccessToken,
      SettingsRepository.kRefreshToken,
      SettingsRepository.kAccessTokenExpiresAt,
    ]) {
      await settings.remove(key);
    }
    await addParty('Ravi Kumar');

    final report = await engine.push();

    expect(report.needsSignIn, true);
    expect(report.pending, 1);
    expect(requests, isEmpty);
    // And nothing was retired: the change is still queued for the next attempt.
    final row = await db.select(db.syncQueue).getSingle();
    expect(row.syncedAt, null);
  });

  test('an empty outbox finishes without troubling the server', () async {
    final report = await engine.push();
    expect(report.pushed, 0);
    expect(report.pending, 0);
    expect(report.describe, 'Everything is already synced.');
    expect(requests, isEmpty);
  });

  test('a queued change is registered, sent, and marked done', () async {
    await addParty('Ravi Kumar');

    final report = await engine.push();

    // The firm is registered first: the journal's rows carry a foreign key to
    // it, so pushing before it exists fails on a constraint.
    expect(requests, ['/v1/firms', '/v1/firms/$firmId/changes']);
    expect(report.pushed, 1);
    expect(report.pending, 0);
    expect(report.error, null);

    final change = bodies.last.single as Map;
    expect(change['entity'], 'parties');
    expect(change['operation'], 'insert');
    expect((change['id'] as String).isNotEmpty, true);
    final payload = change['payload'] as Map;
    expect(payload['name'], 'Ravi Kumar');
    expect(payload['firm_id'], firmId);
    expect(payload['is_deleted'], false);

    final row = await db.select(db.syncQueue).getSingle();
    expect(row.syncedAt, isNotNull);
    expect(await settings.get(SettingsRepository.kSyncLastPushedAt), isNotNull);
  });

  test('a firm is registered once, not on every push', () async {
    await addParty('Ravi Kumar');
    await engine.push();
    await addParty('Sunita Devi');
    await engine.push();

    expect(requests.where((p) => p == '/v1/firms').length, 1);
    expect(requests.where((p) => p.endsWith('/changes')).length, 2);
  });

  test('changes go in the order they were enqueued', () async {
    await addParty('First');
    await addParty('Second');

    await engine.push();

    final sent = bodies.last.cast<Map>();
    expect(sent.length, 2);
    final names = [
      for (final change in sent) (change['payload'] as Map)['name'],
    ];
    expect(names, ['First', 'Second']);
  });

  test('a failed push keeps the change queued and records why', () async {
    pushStatus = 500;
    pushBody = jsonEncode({
      'error': {'code': 'internal_error', 'message': 'Something went wrong.'},
    });
    await addParty('Ravi Kumar');

    final report = await engine.push();

    expect(report.error, isNotNull);
    expect(report.pushed, 0);
    expect(report.pending, 1);
    final row = await db.select(db.syncQueue).getSingle();
    expect(row.syncedAt, null);
    expect(row.attempts, 1);
    expect(row.error, isNotNull);
    // A failed run is not a sync: the "last sent" stamp must not move, or the
    // settings screen would claim the books were sent when they were not.
    expect(await settings.get(SettingsRepository.kSyncLastPushedAt), isNull);
  });

  test('a retried batch is reported as duplicates, not as a failure', () async {
    // What a batch that landed but timed out on the way back looks like.
    pushBody = jsonEncode({'received': 0, 'duplicates': 1});
    await addParty('Ravi Kumar');

    final report = await engine.push();

    expect(report.error, null);
    expect(report.pushed, 1);
    expect(report.pending, 0);
  });

  test('an outbox row with no business is quarantined, not retired', () async {
    // Not something the app does today, but the outbox is a table and a row
    // without a firm can never be sent: it must not be re-read for ever.
    //
    // "Not re-read for ever" is the whole requirement, and it is NOT the same
    // as "marked sent". Marking it `synced_at` says the server holds a change
    // it never received; `pruneSent` then deletes it with the rest of the sent
    // queue, and the row is gone from the device while the UI reports a clean
    // sync. So the row stays *unsent*, is counted in `pending`, and is skipped
    // by the drain on account of its `attempts`.
    await db.into(db.syncQueue).insert(SyncQueueCompanion.insert(
          id: 'orphan',
          firmId: const Value(null),
          entity: 'parties',
          entityId: 'pty-1',
          operation: 'insert',
        ));

    final report = await engine.push();

    expect(report.pending, 1, reason: 'an unsent change must stay counted');
    final row = await db.select(db.syncQueue).getSingle();
    expect(row.syncedAt, isNull);
    expect(row.error, contains('No business'));
    expect(row.attempts, greaterThan(0));
  });

  test('pruning drops sent rows and keeps unsent ones', () async {
    final now = DateTime.now();
    await db.into(db.syncQueue).insert(SyncQueueCompanion.insert(
          id: 'sent-old',
          firmId: Value(firmId),
          entity: 'parties',
          entityId: 'pty-1',
          operation: 'insert',
          syncedAt: Value(now.subtract(const Duration(days: 30))),
        ));
    await db.into(db.syncQueue).insert(SyncQueueCompanion.insert(
          id: 'sent-new',
          firmId: Value(firmId),
          entity: 'parties',
          entityId: 'pty-2',
          operation: 'insert',
          syncedAt: Value(now.subtract(const Duration(days: 1))),
        ));
    await db.into(db.syncQueue).insert(SyncQueueCompanion.insert(
          id: 'unsent-old',
          firmId: Value(firmId),
          entity: 'parties',
          entityId: 'pty-3',
          operation: 'insert',
          createdAt: Value(now.subtract(const Duration(days: 60))),
        ));

    final pruned = await engine.pruneSent();

    expect(pruned, 1);
    final ids = (await db.select(db.syncQueue).get()).map((r) => r.id).toSet();
    expect(ids, {'sent-new', 'unsent-old'});
  });

  test('a purged row is sent as a tombstone with a null payload', () async {
    final party = await db.partyRepositoryFor(firmId).create(name: 'Gone');
    // A soft delete is an *update* of `is_deleted` (the row stays for the
    // documents that reference it); deleteForever is the real delete.
    await db.partyRepositoryFor(firmId).delete(party.id);
    await db.partyRepositoryFor(firmId).deleteForever(party.id);

    await engine.push();

    final changes = bodies.last.cast<Map>();
    // Three changes, and each one matters: the server has to learn the row
    // existed before it hears it was binned, and again before it is gone.
    expect(changes.length, 3);
    expect(changes[0]['operation'], 'insert');
    expect(changes[1]['operation'], 'update');
    expect(changes.last['operation'], 'delete');
    // The row is no longer there to describe, and sending stale state would be
    // worse than sending none.
    expect(changes.last['payload'], null);
  });

  test('every push carries the session token', () async {
    await addParty('Ravi Kumar');
    await engine.push();
    await settle();

    // The device id is not sent: the server reads it from the access token's
    // own claim, which is the value it has already verified.
    final index = requests.indexOf('/v1/firms/$firmId/changes');
    expect(auths[index], 'Bearer access-1');
  });

  test('a child enqueued in the same second as its parent is not sent first',
      () async {
    // The regression behind the hollow journal: inside one second,
    // created_at ties and the old drain fell back to sorting by row id —
    // which puts `sales_invoice_items_<id>_…` before `sales_invoices_<id>_…`
    // because the names diverge at the underscore. The server then journals
    // the child first, and every pull skips it as an FK orphan, permanently.
    final items = db.itemRepositoryFor(firmId);
    final item = await items.create(name: 'Steel Pipe', salePrice: 1250);
    await db.salesRepositoryFor(firmId).save(SalesDraft(
          id: 'inv-1',
          number: 'INV-1',
          docType: 'invoice',
          invoiceDate: DateTime(2026, 9, 8),
          status: 'confirmed',
          lines: [
            SalesLineDraft(
              id: 'line-1',
              itemId: item.id,
              name: item.name,
              quantity: Decimal.fromInt(2),
              unit: 'pcs',
              rate: Decimal.fromInt(1250),
              gstRate: 18,
            ),
          ],
        ));

    await engine.push();

    final entities = [
      for (final batch in bodies)
        for (final change in batch.cast<Map>()) change['entity'],
    ];
    // The item leads (a parent of nothing, but before the invoice), and the
    // line's change comes after its invoice's — whatever the clock did.
    final invoiceAt = entities.indexOf('sales_invoices');
    final lineAt = entities.indexOf('sales_invoice_items');
    expect(invoiceAt, isNot(-1));
    expect(lineAt, greaterThan(invoiceAt));
  });

  test('rejournalEverything queues every row, parents before children',
      () async {
    final items = db.itemRepositoryFor(firmId);
    final item = await items.create(name: 'Cement Bag', salePrice: 380);
    await db.salesRepositoryFor(firmId).save(SalesDraft(
          id: 'inv-1',
          number: 'INV-1',
          docType: 'invoice',
          invoiceDate: DateTime(2026, 9, 8),
          status: 'confirmed',
          lines: [
            SalesLineDraft(
              id: 'line-1',
              itemId: item.id,
              name: item.name,
              quantity: Decimal.fromInt(40),
              unit: 'pcs',
              rate: Decimal.fromInt(380),
              gstRate: 28,
            ),
          ],
        ));
    // The normal save already queued its changes; a hollow journal is repaired
    // from a queue that does NOT know the rows, so start from empty.
    await db.delete(db.syncQueue).go();

    final enqueued = await engine.rejournalEverything(firmId: firmId);

    // firm + item + invoice + its one line + the stock movement the sale
    // posted (its own journal row, and exactly what a hollow journal is
    // missing too).
    expect(enqueued, 5);

    // The queue's own id order still puts `sales_invoice_items` before
    // `sales_invoices` (the underscore again) — the drain is the layer that
    // must reorder, so assert the pushed order, not the rows.
    await engine.push();
    final pushed = [
      for (final batch in bodies)
        for (final change in batch.cast<Map>())
          if (change['entity'] is String) change['entity'] as String,
    ];
    expect(pushed.indexOf('sales_invoices'),
        lessThan(pushed.indexOf('sales_invoice_items')));
    expect(
      pushed,
      containsAllInOrder(<String>['firms', 'items', 'sales_invoices']),
    );
  });

  test('rejournalEverything is idempotent and does not queue soft-deleted rows',
      () async {
    final items = db.itemRepositoryFor(firmId);
    final item = await items.create(name: 'Paint Brush', salePrice: 95);
    await db.salesRepositoryFor(firmId).save(SalesDraft(
          id: 'inv-1',
          number: 'INV-1',
          docType: 'invoice',
          invoiceDate: DateTime(2026, 9, 8),
          status: 'confirmed',
          lines: [
            SalesLineDraft(
              id: 'line-1',
              itemId: item.id,
              name: item.name,
              quantity: Decimal.fromInt(12),
              unit: 'pcs',
              rate: Decimal.fromInt(95),
              gstRate: 18,
            ),
          ],
        ));
    await db.delete(db.syncQueue).go();
    await (db.update(db.salesInvoices)..where((t) => t.id.equals('inv-1')))
        .write(const SalesInvoicesCompanion(isDeleted: Value(true)));

    final first = await engine.rejournalEverything(firmId: firmId);
    final second = await engine.rejournalEverything(firmId: firmId);

    // Still queued from the first run: suppressed, so the same row is not
    // double-sent. The suppression is on entity+entityId, not the full id.
    expect(second, 0);
    final entities = [for (final row in await db.select(db.syncQueue).get()) row.entity];
    expect(entities, contains('items'));
    // The invoice is soft-deleted, so neither it nor its line is re-sent.
    expect(entities, isNot(contains('sales_invoices')));
    expect(entities, isNot(contains('sales_invoice_items')));
    expect(first, entities.length);
  });

  test('a repair after pruning re-journals, instead of colliding with the '
      'sent ids the server already holds', () async {
    final items = db.itemRepositoryFor(firmId);
    final item = await items.create(name: 'Copper Wire', salePrice: 240);
    await db.salesRepositoryFor(firmId).save(SalesDraft(
          id: 'inv-9',
          number: 'INV-9',
          docType: 'invoice',
          invoiceDate: DateTime(2026, 9, 8),
          status: 'confirmed',
          lines: [
            SalesLineDraft(
              id: 'line-9',
              itemId: item.id,
              name: item.name,
              quantity: Decimal.fromInt(3),
              unit: 'pcs',
              rate: Decimal.fromInt(240),
              gstRate: 18,
            ),
          ],
        ));

    await db.delete(db.syncQueue).go();
    final first = await engine.rejournalEverything(firmId: firmId);
    final firstIds = [
      for (final row in await db.select(db.syncQueue).get()) row.id
    ];
    expect(first, greaterThan(0));

    // `pruneSent` drops the sent rows after keepSentFor (14 days). The
    // repair exists for exactly the situation that follows — a new device, or
    // a journal that went hollow again — so it has to work from a clean
    // queue.
    await db.delete(db.syncQueue).go();

    final second = await engine.rejournalEverything(firmId: firmId);
    final secondIds = [
      for (final row in await db.select(db.syncQueue).get()) row.id
    ];

    expect(second, first,
        reason: 'a repair from a pruned queue must re-journal every row');

    // The outbox id is the server's `firm_changes.change_id` PRIMARY KEY,
    // inserted ON CONFLICT DO NOTHING. Reusing the first run's ids would make
    // the server drop every row as a duplicate while the client marked them
    // sent — the repair reporting success having healed nothing.
    expect(secondIds.toSet().intersection(firstIds.toSet()), isEmpty,
        reason: 'ids must differ per run, or the server deduplicates them away');
  });

  test('re-journal ids differ between runs so the server does not '
      'deduplicate a genuine repair', () async {
    final items = db.itemRepositoryFor(firmId);
    await items.create(name: 'Junction Box', salePrice: 60);
    await db.delete(db.syncQueue).go();

    await engine.rejournalEverything(firmId: firmId);
    final firstIds = [
      for (final row in await db.select(db.syncQueue).get()) row.id
    ];

    await db.delete(db.syncQueue).go();
    await engine.rejournalEverything(firmId: firmId);
    final secondIds = [
      for (final row in await db.select(db.syncQueue).get()) row.id
    ];

    expect(secondIds, isNotEmpty);
    expect(secondIds, isNot(equals(firstIds)));
    expect(
      secondIds.every((id) => id.startsWith('rejournal_')),
      isTrue,
      reason: 'the prefix is what identifies these as repair rows',
    );
  });

  test('the repair survives the server deduplicating on change_id',
      () async {
    // The outbox id is the server's `firm_changes.change_id` PRIMARY KEY
    // (server/db/migrations/0003_firm_changes.sql) and the push is an
    // `INSERT ... ON CONFLICT (change_id) DO NOTHING`. So a repeated id is
    // silently dropped and the client still marks the row sent. The fake
    // server above collects `journalIds` on exactly that rule.

    final items = db.itemRepositoryFor(firmId);
    await items.create(name: 'Conduit Pipe', salePrice: 310);
    await db.delete(db.syncQueue).go();

    await engine.rejournalEverything(firmId: firmId);
    final firstReport = await engine.push();

    final firstPushed = journalIds.length;
    expect(firstReport.error, isNull,
        reason: 'the push must not be skipped — otherwise this test would '
            'pass with an empty journal and prove nothing');
    expect(firstPushed, greaterThan(0),
        reason: 'the first repair must reach the journal');

    // 14 days later pruneSent clears the sent rows, and the repair runs again
    // for a new device — the scenario it exists for.
    await db.delete(db.syncQueue).go();
    final enqueuedAgain = await engine.rejournalEverything(firmId: firmId);
    expect(enqueuedAgain, greaterThan(0),
        reason: 'a repair from a pruned queue must enqueue work');
    final secondReport = await engine.push();
    expect(secondReport.error, isNull);

    expect(journalIds.length, firstPushed * 2,
        reason: 'a repair after pruning must add new journal entries; '
            'reused ids would be deduplicated away while the client reported '
            'success');
  });

  test('a repaired journal pushes children with full payloads', () async {
    final items = db.itemRepositoryFor(firmId);
    final item = await items.create(name: 'Steel Pipe', salePrice: 1250);
    await db.salesRepositoryFor(firmId).save(SalesDraft(
          id: 'inv-1',
          number: 'INV-1',
          docType: 'invoice',
          invoiceDate: DateTime(2026, 9, 8),
          status: 'confirmed',
          lines: [
            SalesLineDraft(
              id: 'line-1',
              itemId: item.id,
              name: item.name,
              quantity: Decimal.fromInt(10),
              unit: 'pcs',
              rate: Decimal.fromInt(1250),
              gstRate: 18,
            ),
          ],
        ));
    await db.delete(db.syncQueue).go();
    await engine.rejournalEverything(firmId: firmId);

    await engine.push();

    final pushed = [
      for (final batch in bodies)
        for (final change in batch.cast<Map>()) change,
    ];
    final line = pushed.singleWhere((c) => c['entity'] == 'sales_invoice_items');
    final payload = line['payload'] as Map;
    expect(payload['invoice_id'], 'inv-1');
    expect(payload['name'], 'Steel Pipe');
    expect(payload['quantity'], 10.0);
  });
}
