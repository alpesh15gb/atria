import 'dart:convert';
import 'dart:io';

import 'package:atria/core/api/api_config.dart';
import 'package:atria/core/api/auth_client.dart';
import 'package:atria/core/api/server_session.dart';
import 'package:atria/core/api/sync_client.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:atria/core/state/auth_controller.dart';
import 'package:atria/core/sync/pull_applier.dart';
import 'package:atria/core/sync/sync_engine.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pull half replays another device's journal into *this* database, which
/// makes it the one half of sync whose bugs are silent wrong books rather than
/// failed requests. Everything the merge can get wrong deserves a pin: an
/// older write clobbering a newer one, a re-applied page duplicating lines, a
/// cursor that skips or repeats pages, a restore that half-lands.
void main() {
  late AppDatabase db;
  late String firmId;
  late HttpServer server;
  late SyncEngine engine;
  late SettingsRepository settings;
  late AuthController auth;
  late PullApplier applier;

  /// The journal the fake server serves from, in seq order.
  final journal = <Map<String, Object?>>[];

  /// GET paths the tests observed, to pin the cursor behaviour.
  final pullPaths = <String>[];

  setUp(() async {
    journal.clear();
    pullPaths.clear();

    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Shri Balaji Traders',
      stateCode: '29',
    );
    firmId = firm.id;
    settings = SettingsRepository(db);
    await db.delete(db.syncQueue).go();

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      await utf8.decoder.bind(request).join();

      if (request.method == 'GET' && path.endsWith('/changes')) {
        pullPaths.add(request.uri.queryParameters['afterSeq'] ?? '?');
        final afterSeq =
            int.tryParse(request.uri.queryParameters['afterSeq'] ?? '0') ?? 0;
        final page = journal
            .where((c) => (c['seq'] as int) > afterSeq)
            .take(2) // a small page size exercises the hasMore loop
            .toList(growable: false);
        final hasMore = journal
                .where((c) => (c['seq'] as int) > afterSeq)
                .length >
            page.length;
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'changes': page, 'hasMore': hasMore}));
        await request.response.close();
        return;
      }

      // Push and firm-create succeed trivially; these tests are about pull.
      request.response
        ..statusCode = path == '/v1/firms' ? 201 : 200
        ..headers.contentType = ContentType.json
        ..write(path == '/v1/firms'
            ? jsonEncode({'firmId': firmId, 'name': 'Shri Balaji Traders'})
            : jsonEncode({'received': 0, 'duplicates': 0}));
      await request.response.close();
    });

    await settings.set(
      SettingsRepository.kApiBaseUrl,
      'http://127.0.0.1:${server.port}',
    );
    await settings.setBool(SettingsRepository.kSyncEnabled, true);

    final config = ApiConfig(settings);
    auth = AuthController(ServerSession(settings), AuthClient(config));
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
    applier = PullApplier(db);
  });

  tearDown(() async {
    try {
      await server.close(force: true);
    } on Object {
      // already closed by a test
    }
    await db.close();
  });

  /// A party row from another device, as the journal would carry it: the
  /// push sends the whole row, so the payload carries every NOT NULL column
  /// even the ones this device would have defaulted.
  Map<String, Object?> partyPayload(
    String id,
    String name, {
    required DateTime updatedAt,
    bool deleted = false,
  }) =>
      {
        'id': id,
        'firm_id': firmId,
        'name': name,
        'type': 'customer',
        'phone': null,
        'is_deleted': deleted,
        // drift stores seconds; the push normalises to milliseconds.
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  test('a pulled insert lands as a local row', () async {
    journal.add({
      'seq': 1,
      'id': 'change-1',
      'entity': 'parties',
      'entityId': 'pty-remote-1',
      'operation': 'insert',
      'payload': partyPayload(
        'pty-remote-1',
        'Imported Traders',
        updatedAt: DateTime.now(),
      ),
    });

    await engine.sync();

    final row = await (db.select(db.parties)
          ..where((t) => t.id.equals('pty-remote-1')))
        .getSingleOrNull();
    expect(row, isNotNull);
    expect(row!.name, 'Imported Traders');
  });

  test('a newer remote write wins; an older one loses', () async {
    final local = await db.partyRepositoryFor(firmId).create(name: 'Local');
    final localUpdated = await (db.select(db.parties)
          ..where((t) => t.id.equals(local.id)))
        .getSingle();

    // Older than the local write: must not overwrite it.
    journal.add({
      'seq': 1,
      'id': 'change-old',
      'entity': 'parties',
      'entityId': local.id,
      'operation': 'update',
      'payload':
          partyPayload(local.id, 'Older remote', updatedAt: DateTime(2020)),
    });
    await engine.sync();
    var row = await (db.select(db.parties)
          ..where((t) => t.id.equals(local.id)))
        .getSingle();
    expect(row.name, 'Local');

    // Newer than the local write: must overwrite it.
    journal.add({
      'seq': 2,
      'id': 'change-new',
      'entity': 'parties',
      'entityId': local.id,
      'operation': 'update',
      'payload': partyPayload(
        local.id,
        'Newer remote',
        updatedAt: DateTime.now().add(const Duration(hours: 1)),
      ),
    });
    await engine.sync();
    row = await (db.select(db.parties)..where((t) => t.id.equals(local.id)))
        .getSingle();
    expect(row.name, 'Newer remote');
    expect(localUpdated.updatedAt.isBefore(row.updatedAt), true);
  });

  test('this device never applies its own pushed rows back', () async {
    final party = await db.partyRepositoryFor(firmId).create(name: 'Mine');
    await engine.push(); // journals the row; fake server echoes it back
    final before = await (db.select(db.parties)
          ..where((t) => t.id.equals(party.id)))
        .getSingle();

    journal.add({
      'seq': 1,
      'id': 'own-change',
      'entity': 'parties',
      'entityId': party.id,
      'operation': 'insert',
      'payload': partyPayload(party.id, 'Mine', updatedAt: before.updatedAt),
    });
    await engine.sync();

    // Same name AND same updated_at: the LWW rule already protects the value,
    // and the assertion is that the round trip is a no-op rather than a
    // rewrite that would bump updated_at and re-journal the row.
    final after = await (db.select(db.parties)
          ..where((t) => t.id.equals(party.id)))
        .getSingle();
    expect(after.updatedAt, before.updatedAt);
  });

  test('a tombstone removes the local row', () async {
    journal.add({
      'seq': 1,
      'id': 'change-del',
      'entity': 'categories',
      'entityId': 'cat-remote-1',
      'operation': 'delete',
      'payload': null,
    });
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          id: 'cat-remote-1',
          firmId: firmId,
          name: 'To be removed',
        ));

    await engine.sync();

    final row = await (db.select(db.categories)
          ..where((t) => t.id.equals('cat-remote-1')))
        .getSingleOrNull();
    expect(row, isNull);
  });

  test('a re-applied page does not duplicate children', () async {
    // The parent first: children arrive with it in one journal burst.
    final invoicePayload = {
      'id': 'inv-remote-1',
      'firm_id': firmId,
      'doc_type': 'invoice',
      'number': 'INV-RESTORE-1',
      'invoice_date': DateTime(2026, 9, 1).millisecondsSinceEpoch,
      'grand_total': 1180.0,
      'is_deleted': false,
      'updated_at': DateTime(2026, 9, 1, 12).millisecondsSinceEpoch,
    };
    final linePayload = {
      'id': 'invline-remote-1',
      'invoice_id': 'inv-remote-1',
      'name': 'Panel Fan',
      'quantity': 2.0,
      'rate': 500.0,
      'total': 1000.0,
      'is_deleted': false,
    };
    journal.addAll([
      {
        'seq': 1,
        'id': 'c1',
        'entity': 'sales_invoices',
        'entityId': 'inv-remote-1',
        'operation': 'insert',
        'payload': invoicePayload,
      },
      {
        'seq': 2,
        'id': 'c2',
        'entity': 'sales_invoice_items',
        'entityId': 'invline-remote-1',
        'operation': 'insert',
        'payload': linePayload,
      },
    ]);

    await engine.sync();
    // The cursor test pins the page loop; the cursor also means this second
    // sync re-pulls nothing. Apply the same page by hand to prove the child
    // rule directly.
    final applied = await applier.applyPage(
      firmId: firmId,
      page: PullPage(
        changes: [
          JournaledChange(
            seq: 3,
            changeId: 'c2-again',
            entity: 'sales_invoice_items',
            entityId: 'invline-remote-1',
            operation: 'insert',
            payload: linePayload,
          ),
        ],
        hasMore: false,
      ),
    );

    final lines = await (db.select(db.salesInvoiceItems)
          ..where((t) => t.invoiceId.equals('inv-remote-1')))
        .get();
    expect(lines, hasLength(1));
    expect(applied.skipped, 1);
  });

  test('the cursor advances page by page and stops at the top', () async {
    for (var i = 1; i <= 5; i++) {
      journal.add({
        'seq': i,
        'id': 'change-$i',
        'entity': 'parties',
        'entityId': 'pty-$i',
        'operation': 'insert',
        'payload': partyPayload('pty-$i', 'Party $i', updatedAt: DateTime.now()),
      });
    }

    await engine.sync();

    // Page size is 2 in the fake server: 5 changes take three pulls —
    // afterSeq 0, then 2, then 4 — and stop there because hasMore went false.
    expect(pullPaths, ['0', '2', '4']);
    expect(await settings.getInt('sync_cursor_$firmId'), 5);
    for (var i = 1; i <= 5; i++) {
      final row = await (db.select(db.parties)
            ..where((t) => t.id.equals('pty-$i')))
          .getSingleOrNull();
      expect(row, isNotNull, reason: 'party $i must have landed');
    }
  });

  test('restoreFirm materialises the firm and enables sync', () async {
    // A second device created a firm and pushed: firm insert, party, invoice
    // with a line. Nothing exists locally under that firm id yet.
    const restoreId = '018f2a3b-0000-0000-0000-0000000000aa';
    journal.addAll([
      {
        'seq': 1,
        'id': 'r1',
        'entity': 'firms',
        'entityId': restoreId,
        'operation': 'insert',
        'payload': {
          'id': restoreId,
          'name': 'Restored Books',
          'state_code': '27',
          'is_default': false,
          'created_at': DateTime(2026, 8, 1).millisecondsSinceEpoch,
          'updated_at': DateTime(2026, 8, 1).millisecondsSinceEpoch,
        },
      },
      {
        'seq': 2,
        'id': 'r2',
        'entity': 'parties',
        'entityId': 'pty-r-1',
        'operation': 'insert',
        'payload': {
          'id': 'pty-r-1',
          'firm_id': restoreId,
          'name': 'Mumbai Buyer',
          'type': 'customer',
          'is_deleted': false,
          'updated_at': DateTime(2026, 8, 2).millisecondsSinceEpoch,
        },
      },
      {
        'seq': 3,
        'id': 'r3',
        'entity': 'sales_invoices',
        'entityId': 'inv-r-1',
        'operation': 'insert',
        'payload': {
          'id': 'inv-r-1',
          'firm_id': restoreId,
          'doc_type': 'invoice',
          'number': 'INV-1001',
          'invoice_date': DateTime(2026, 8, 3).millisecondsSinceEpoch,
          'grand_total': 500.0,
          'is_deleted': false,
          'updated_at': DateTime(2026, 8, 3).millisecondsSinceEpoch,
        },
      },
      {
        'seq': 4,
        'id': 'r4',
        'entity': 'sales_invoice_items',
        'entityId': 'invline-r-1',
        'operation': 'insert',
        'payload': {
          'id': 'invline-r-1',
          'invoice_id': 'inv-r-1',
          'name': 'Service charge',
          'quantity': 1.0,
          'rate': 500.0,
          'total': 500.0,
          'is_deleted': false,
        },
      },
    ]);

    final report = await engine.restoreFirm(restoreId);

    expect(report.restored, true, reason: report.describe);
    final firmRow = await (db.select(db.firms)
          ..where((t) => t.id.equals(restoreId)))
        .getSingleOrNull();
    expect(firmRow, isNotNull);
    expect(firmRow!.name, 'Restored Books');
    final party = await (db.select(db.parties)
          ..where((t) => t.id.equals('pty-r-1')))
        .getSingleOrNull();
    expect(party, isNotNull);
    final line = await (db.select(db.salesInvoiceItems)
          ..where((t) => t.invoiceId.equals('inv-r-1')))
        .getSingleOrNull();
    expect(line, isNotNull);
    // Restore works with sync off, and it leaves the device ready to push
    // and pull from here on.
    expect(await settings.getBool(SettingsRepository.kSyncEnabled), true);
    expect(await settings.getInt('sync_cursor_$restoreId'), 4);
  });

  test('restoreFirm refuses to open an empty journal as books', () async {
    const emptyId = '018f2a3b-0000-0000-0000-0000000000bb';

    final report = await engine.restoreFirm(emptyId);

    expect(report.restored, false);
    expect(report.describe, contains('no books'));
    final firmRow = await (db.select(db.firms)
          ..where((t) => t.id.equals(emptyId)))
        .getSingleOrNull();
    expect(firmRow, isNull);
  });

  test('an unknown entity is skipped without stopping the pull', () async {
    journal.add({
      'seq': 1,
      'id': 'future-1',
      'entity': 'future_table',
      'entityId': 'x-1',
      'operation': 'insert',
      'payload': {'id': 'x-1'},
    });
    journal.add({
      'seq': 2,
      'id': 'known-1',
      'entity': 'parties',
      'entityId': 'pty-after-future',
      'operation': 'insert',
      'payload': partyPayload('pty-after-future', 'Survivor', updatedAt: DateTime.now()),
    });

    await engine.sync();

    final row = await (db.select(db.parties)
          ..where((t) => t.id.equals('pty-after-future')))
        .getSingleOrNull();
    expect(row, isNotNull);
    // And the unknown change did not wedge the cursor.
    expect(await settings.getInt('sync_cursor_$firmId'), 2);
  });
}
