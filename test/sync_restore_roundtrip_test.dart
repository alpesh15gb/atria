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
import 'package:atria/core/sync/sync_engine.dart';
import 'package:atria/core/database/repositories/sales_repository.dart'
    show SalesDraft, SalesLineDraft;
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A full round trip: one device creates books and pushes every change;
/// a second device restores from that journal and must be able to open the
/// same books.
///
/// This exists because a restore once failed on the user's phone with
/// `FormatException: Invalid radix-10 number` while every hand-built payload
/// test passed: hand-made payloads omit nullable columns, real pushed rows
/// carry `creditDays: null`, `deletedAt: null` and friends — and the applier
/// bound those nulls as the four characters "null" (SQLite accepts that
/// silently in any column; drift's typed read of an int column then calls
/// int.parse on it). The lesson: this suite must always build its payloads by
/// pushing through a REAL database, never by typing JSON.
void main() {
  test('restore replays a real pushed journal into working books', () async {
    // ---- Device A: create books, push everything. ----
    final dbA = AppDatabase.test(NativeDatabase.memory());
    final settingsA = SettingsRepository(dbA);
    final pushedChanges = <Map<String, Object?>>[];
    late HttpServer server;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      if (request.method == 'GET') {
        final afterSeq = int.tryParse(
              request.uri.queryParameters['afterSeq'] ?? '0',
            ) ??
            0;
        final page = pushedChanges
            .where((c) => (c['seq'] as int) > afterSeq)
            .toList();
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'changes': page, 'hasMore': false}));
        await request.response.close();
        return;
      }
      if (request.uri.path == '/v1/firms') {
        request.response
          ..statusCode = 201
          ..write('{}');
        await request.response.close();
        return;
      }
      final decoded = jsonDecode(body) as Map;
      for (final change in (decoded['changes'] as List)) {
        pushedChanges.add({
          ...(change as Map).cast<String, Object?>(),
          'seq': pushedChanges.length + 1,
        });
      }
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'received': 1, 'duplicates': 0}));
      await request.response.close();
    });
    await settingsA.set(
      SettingsRepository.kApiBaseUrl,
      'http://127.0.0.1:${server.port}',
    );
    await settingsA.setBool(SettingsRepository.kSyncEnabled, true);
    final configA = ApiConfig(settingsA);
    final authA = AuthController(ServerSession(settingsA), AuthClient(configA));
    await settingsA.set(SettingsRepository.kUserEmail, 'owner@apexbooks.in');
    await settingsA.set(SettingsRepository.kAccessToken, 'a');
    await settingsA.set(SettingsRepository.kRefreshToken, 'r');
    await settingsA.set(
      SettingsRepository.kAccessTokenExpiresAt,
      DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
    );
    final engineA = SyncEngine(
      dbA,
      settingsA,
      authA,
      SyncClient(configA, timeout: const Duration(seconds: 5)),
    );

    final firm = await dbA.firmRepository.create(
      name: 'Apex Integrations',
      stateCode: '29',
    );
    final party = await dbA.partyRepositoryFor(firm.id).create(
          name: 'Test Buyer',
          type: 'customer',
        );
    final item = await dbA.itemRepositoryFor(firm.id).create(
          name: 'Panel Fan',
          purchasePrice: 100,
        );
    await dbA.salesRepositoryFor(firm.id).save(
          SalesDraft(
            id: 'inv-1',
            number: 'INV-1',
            docType: 'invoice',
            partyId: party.id,
            partyName: 'Test Buyer',
            invoiceDate: DateTime.now(),
            status: 'confirmed',
            lines: [
              SalesLineDraft(
                id: 'line-1',
                itemId: item.id,
                name: 'Panel Fan',
                quantity: Decimal.fromInt(2),
                unit: 'pcs',
                rate: Decimal.fromInt(118),
                gstRate: 18,
              ),
            ],
          ),
        );

    final pushReport = await engineA.push();
    expect(pushReport.pushed, greaterThan(0));
    expect(pushedChanges, isNotEmpty);

    // ---- Device B: restore from that journal. ----
    final dbB = AppDatabase.test(NativeDatabase.memory());
    final settingsB = SettingsRepository(dbB);
    await settingsB.set(
      SettingsRepository.kApiBaseUrl,
      'http://127.0.0.1:${server.port}',
    );
    await settingsB.setBool(SettingsRepository.kSyncEnabled, true);
    final configB = ApiConfig(settingsB);
    final authB = AuthController(ServerSession(settingsB), AuthClient(configB));
    await settingsB.set(SettingsRepository.kUserEmail, 'owner@apexbooks.in');
    await settingsB.set(SettingsRepository.kAccessToken, 'b');
    await settingsB.set(SettingsRepository.kRefreshToken, 'rb');
    await settingsB.set(
      SettingsRepository.kAccessTokenExpiresAt,
      DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
    );
    final engineB = SyncEngine(
      dbB,
      settingsB,
      authB,
      SyncClient(configB, timeout: const Duration(seconds: 5)),
    );

    final report = await engineB.restoreFirm(firm.id);

    expect(report.restored, true, reason: report.describe);
    final restoredFirm = await (dbB.select(dbB.firms)
          ..where((t) => t.id.equals(firm.id)))
        .getSingleOrNull();
    expect(restoredFirm!.name, 'Apex Integrations');
    final restoredParty = await (dbB.select(dbB.parties)
          ..where((t) => t.id.equals(party.id)))
        .getSingleOrNull();
    expect(restoredParty!.name, 'Test Buyer');
    // Nullable columns arrived as NULL, not the string "null": reading the
    // row through drift's typed API would otherwise throw.
    expect(restoredParty.creditDays, isNull);
    expect(restoredParty.phone, isNull);
    final lines = await dbB.select(dbB.salesInvoiceItems).get();
    expect(lines, hasLength(1));
    expect(lines.first.quantity, 2.0);
    // And the item came with its nullable columns intact too.
    final restoredItems = await dbB.select(dbB.items).get();
    expect(restoredItems, hasLength(1));
    expect(restoredItems.first.sku, isNull);

    await server.close(force: true);
    await dbA.close();
    await dbB.close();
  });
}
