import 'dart:convert';
import 'dart:io';

import 'package:atria/core/api/api_config.dart';
import 'package:atria/core/api/scan_client.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:atria/core/sync/scan_seed.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The scan feature has two halves worth pinning: the client's JSON decoding
/// (a model's messy answer must never crash the app, and money fields arrive
/// as strings as often as numbers), and the supplier matching that decides
/// whether a scanned bill links to an existing party or creates one. A wrong
/// match silently books a purchase against the wrong supplier, which is a
/// worse outcome than no match at all.
void main() {
  group('ScannedBill.fromJson', () {
    test('parses a full model answer, numbers as numbers', () {
      final bill = ScannedBill.fromJson({
        'supplierName': 'Shree Electric Traders',
        'supplierGstin': '27ABCDE1234F1Z5',
        'supplierInvoiceNumber': 'SE/24-25/118',
        'billDate': '2026-09-18',
        'placeOfSupply': '27',
        'lines': [
          {
            'name': 'Panel fan 1200mm',
            'hsn': '8414',
            'quantity': 2,
            'unit': 'PCS',
            'rate': 1650.0,
            'gstRate': 18,
          },
        ],
        'shippingCharge': 120,
        'confidence': 'high',
        'warnings': ['Round-off applied at the bottom of the bill.'],
      });

      expect(bill.supplierName, 'Shree Electric Traders');
      expect(bill.lines, hasLength(1));
      expect(bill.lines.first.quantity, 2.0);
      expect(bill.lines.first.gstRate, 18.0);
      expect(bill.billDate, DateTime(2026, 9, 18));
      expect(bill.warnings, hasLength(1));
      expect(bill.confidence, 'high');
    });

    test('accepts numbers wrapped in strings, the way models emit them', () {
      final bill = ScannedBill.fromJson({
        'lines': [
          {'name': 'Wire 90m', 'quantity': '3', 'rate': '45.5', 'gstRate': '18'},
        ],
        'shippingCharge': '30',
      });
      expect(bill.lines.first.quantity, 3.0);
      expect(bill.lines.first.rate, 45.5);
      expect(bill.lines.first.gstRate, 18.0);
      expect(bill.shippingCharge, 30.0);
    });

    test('drops nameless lines instead of showing a blank row', () {
      final bill = ScannedBill.fromJson({
        'lines': [
          {'name': 'Real line', 'quantity': 1, 'rate': 10},
          {'name': '', 'quantity': 1, 'rate': 99},
          {'quantity': 1, 'rate': 99},
        ],
      });
      expect(bill.lines, hasLength(1));
      expect(bill.lines.first.name, 'Real line');
    });

    test('everything unreadable is null, not a guessed zero', () {
      final bill = ScannedBill.fromJson({});
      expect(bill.supplierName, isNull);
      expect(bill.supplierGstin, isNull);
      expect(bill.billDate, isNull);
      expect(bill.lines, isEmpty);
      expect(bill.confidence, 'medium');
    });

    test('a nonsense date does not throw and does not parse', () {
      final bill = ScannedBill.fromJson({'billDate': '18/09/2026 probably'});
      expect(bill.billDate, isNull);
    });
  });

  group('ScanClient against a fake server', () {
    late HttpServer server;
    late SettingsRepository settings;
    late AppDatabase db;
    late String? lastAuth;

    setUp(() async {
      db = AppDatabase.test(NativeDatabase.memory());
      settings = SettingsRepository(db);
      lastAuth = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        lastAuth = request.headers.value('authorization');
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'bill': {
              'supplierName': 'Fake Traders',
              'lines': [
                {'name': 'Item', 'quantity': 1, 'rate': 100, 'gstRate': 18},
              ],
            },
            'model': 'test-model',
          }));
        await request.response.close();
      });
      await settings.set(
        SettingsRepository.kApiBaseUrl,
        'http://127.0.0.1:${server.port}',
      );
    });

    tearDown(() async {
      await server.close(force: true);
      await db.close();
    });

    test('sends the session token and decodes the answer', () async {
      final client = ScanClient(
        ApiConfig(settings),
        timeout: const Duration(seconds: 5),
      );

      final bill = await client.scanBill(
        firmId: '018f2a3b-4c5d-7e8f-9a0b-1c2d3e4f5a6b',
        imageBytes: List.filled(600, 1),
        mimeType: 'image/jpeg',
        accessToken: 'access-1',
      );

      expect(lastAuth, 'Bearer access-1');
      expect(bill.model, 'test-model');
      expect(bill.supplierName, 'Fake Traders');
      expect(bill.lines.first.name, 'Item');
    });
  });

  group('ScannedBillSeed.matchSupplier', () {
    late AppDatabase db;
    late String firmId;

    setUp(() async {
      db = AppDatabase.test(NativeDatabase.memory());
      final firm = await db.firmRepository.create(name: 'F', stateCode: '29');
      firmId = firm.id;
    });

    tearDown(() async {
      await db.close();
    });

    test('matches by GSTIN even when the name is typed differently', () async {
      final repo = db.partyRepositoryFor(firmId);
      final existing = await repo.create(
        name: 'Shree Electric Traders',
        type: 'supplier',
        gstin: '27ABCDE1234F1Z5',
      );

      final seed = ScannedBillSeed(
        supplierName: 'SHREE ELECTRIC TRADERS',
        supplierGstin: '27abcde1234f1z5',
        lines: const [],
      );

      expect(seed.matchSupplier(await repo.all(type: 'supplier'))!.id,
          existing.id);
    });

    test('falls back to a case-insensitive name when GSTINs differ', () async {
      final repo = db.partyRepositoryFor(firmId);
      final existing = await repo.create(
        name: 'Khanna Hardware',
        type: 'supplier',
        gstin: '07AAAAA1111A1Z5',
      );

      final seed = ScannedBillSeed(
        supplierName: 'khanna hardware',
        supplierGstin: '27ABCDE1234F1Z5', // bill's GSTIN differs from ours
        lines: const [],
      );

      expect(seed.matchSupplier(await repo.all(type: 'supplier'))!.id,
          existing.id);
    });

    test('no match is null, so the editor creates the supplier', () async {
      final repo = db.partyRepositoryFor(firmId);
      await repo.create(name: 'Unrelated Supplier', type: 'supplier');

      final seed = ScannedBillSeed(
        supplierName: 'New Billboard',
        lines: const [],
      );

      expect(seed.matchSupplier(await repo.all(type: 'supplier')), isNull);
    });
  });
}
