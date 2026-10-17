import 'package:atria/core/database/repositories/sales_repository.dart';
import 'dart:convert';
import 'dart:io';

import 'package:atria/core/api/api_config.dart';
import 'package:atria/core/api/auth_client.dart';
import 'package:atria/core/api/server_session.dart';
import 'package:atria/core/api/sync_client.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:atria/core/services/vyapar_import.dart';
import 'package:atria/core/state/auth_controller.dart';
import 'package:atria/core/sync/sync_engine.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The reported bug, reproduced as the pipeline it actually happens in.
///
/// A Vyapar `.vyb` is imported on one device, that device syncs to the Apex Books
/// server, and a second device (an Android phone) pulls the books and finds
/// saved bills and estimates whose totals arrived but whose line items did not.
///
/// Every layer was individually checked and each looked correct: the importer
/// writes through `PurchaseRepository.save`, which journals the line rows; the
/// push encodes each outbox row from the live table; the applier inserts
/// children; and the editor reloads them. Running the whole road and counting
/// the lines at both ends is what found it — see the oversized-batch test,
/// which reproduces the report exactly.
void main() {
  late HttpServer server;

  /// The journal the fake server holds, in push order — a stand-in for the
  /// server's `firm_changes` table, including its `change_id` primary key, so a
  /// repeated id is dropped exactly as `ON CONFLICT DO NOTHING` would.
  final journal = <Map<String, Object?>>[];
  final cloudFirmIds = <String>[];
  final acceptedIds = <String>{};
  var seq = 0;

  /// What the server will accept in one request. The real cap is 256KB.
  var maxBodyBytes = 256 * 1024;

  /// Encoded size of every push attempted, so a refused batch can be
  /// identified by measurement rather than by guesswork.
  final batchSizes = <int>[];

  Future<SyncEngine> engineFor(AppDatabase db) async {
    final settings = SettingsRepository(db);
    await settings.set(
      SettingsRepository.kApiBaseUrl,
      'http://127.0.0.1:${server.port}',
    );
    await settings.setBool(SettingsRepository.kSyncEnabled, true);
    await settings.set(SettingsRepository.kUserEmail, 'owner@atria.in');
    await settings.set(SettingsRepository.kAccessToken, 'access-1');
    await settings.set(SettingsRepository.kRefreshToken, 'refresh-1');
    await settings.set(
      SettingsRepository.kAccessTokenExpiresAt,
      DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
    );
    final config = ApiConfig(settings);
    return SyncEngine(
      db,
      settings,
      AuthController(ServerSession(settings), AuthClient(config)),
      SyncClient(config, timeout: const Duration(seconds: 10)),
    );
  }

  setUp(() async {
    journal.clear();
    cloudFirmIds.clear();
    acceptedIds.clear();
    batchSizes.clear();
    seq = 0;
    maxBodyBytes = 256 * 1024;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final path = request.uri.path;

      if (request.method == 'GET' && path == '/v1/me') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'email': 'owner@example.com', 'deviceId': 'test',
          'firms': [for (final id in cloudFirmIds) {'firmId': id, 'name': 'Cloud books', 'role': 'owner'}]}));
        await request.response.close();
        return;
      }

      if (request.method == 'GET' && path.contains('/changes')) {
        final afterSeq =
            int.tryParse(request.uri.queryParameters['afterSeq'] ?? '0') ?? 0;
        const pageSize = 500;
        final page = journal
            .where((c) => (c['seq'] as int) > afterSeq)
            .take(pageSize)
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

      if (request.method == 'POST' && path.endsWith('/changes')) {
        // The server refuses an oversized body whole — there is no partial
        // accept. Modelling the cap is what makes the reported bug reachable.
        batchSizes.add(body.length);
        if (body.length > maxBodyBytes) {
          request.response
            ..statusCode = 413
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': 'payload too large'}));
          await request.response.close();
          return;
        }
        final decoded = jsonDecode(body) as Map<String, Object?>;
        final changes =
            (decoded['changes'] as List).cast<Map<String, Object?>>();
        var received = 0;
        var duplicates = 0;
        for (final change in changes) {
          final id = change['id'];
          if (id is String && acceptedIds.add(id)) {
            received++;
            journal.add({...change, 'seq': ++seq});
          } else {
            duplicates++;
          }
        }
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'received': received, 'duplicates': duplicates}));
        await request.response.close();
        return;
      }

      request.response
        ..statusCode = path == '/v1/firms' ? 201 : 200
        ..headers.contentType = ContentType.json
        ..write(path == '/v1/firms'
            ? jsonEncode({'firmId': 'x', 'name': 'x'})
            : jsonEncode({'received': 0, 'duplicates': 0}));
      await request.response.close();
    });
  });

  tearDown(() async {
    try {
      await server.close(force: true);
    } on Object {
      // already closed by a test
    }
  });

  /// Creates [billCount] bills of [linesPerBill] lines, with a long service
  /// description on each line.
  ///
  /// The long description is the point: `name` is unbounded TEXT, exactly like
  /// the `notes`/`terms` blobs that make a real batch oversized. It is the
  /// mechanism under test, not a claim about typical line length.
  Future<AppDatabase> booksWith({
    required int billCount,
    required int linesPerBill,
  }) async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Mahaveer Computers',
      stateCode: '27',
    );
    final purchases = db.purchaseRepositoryFor(firm.id);
    const description =
        'Installation, commissioning and demonstration of the unit at site '
        'including transportation, packing and handling ';
    for (var b = 0; b < billCount; b++) {
      await purchases.save(PurchaseDraft(
        id: 'bill-$b',
        number: 'MC/2026/${(b + 1).toString().padLeft(4, '0')}',
        docType: 'bill',
        billDate: DateTime(2026, 3, 1).add(Duration(days: b)),
        lines: [
          for (var l = 0; l < linesPerBill; l++)
            PurchaseLineDraft(
              id: 'bill-$b-line-$l',
              name: '$description ${'x' * 900} ($l of bill $b)',
              hsn: '8504',
              quantity: Decimal.fromInt(l + 1),
              unit: 'pcs',
              rate: Decimal.fromInt(100 + l),
              gstRate: 18,
            ),
        ],
      ));
    }
    return db;
  }

  /// A second device that already knows the firm — the phone in this story.
  Future<AppDatabase> phoneFor(AppDatabase origin, String firmId) async {
    final phone = AppDatabase.test(NativeDatabase.memory());
    await phone.into(phone.firms).insert(
          await (origin.select(origin.firms)..where((t) => t.id.equals(firmId)))
              .getSingle(),
        );
    await (await engineFor(phone)).sync();
    return phone;
  }

  test('a Vyapar import survives push and pull with its lines intact',
      () async {
    final backup = File('test/fixtures/swipe_sample.vyb');
    expect(backup.existsSync(), isTrue,
        reason: 'the real Vyapar backup fixture must be present');

    final origin = AppDatabase.test(NativeDatabase.memory());
    final firmId =
        (await VyaparImportService(origin).run(backup.readAsBytesSync())).firmId;

    final purchaseBills = await origin.select(origin.purchaseBills).get();
    final salesInvoices = await origin.select(origin.salesInvoices).get();
    expect(purchaseBills, isNotEmpty, reason: 'the fixture has purchase bills');
    expect(salesInvoices, isNotEmpty, reason: 'and sales documents');

    final originPurchaseLines = <String, int>{};
    for (final bill in purchaseBills) {
      originPurchaseLines[bill.id] = (await (origin.select(origin.purchaseBillItems)
            ..where((t) => t.billId.equals(bill.id)))
          .get())
          .length;
    }
    final originSalesLines = <String, int>{};
    for (final invoice in salesInvoices) {
      originSalesLines[invoice.id] = (await (origin.select(origin.salesInvoiceItems)
            ..where((t) => t.invoiceId.equals(invoice.id)))
          .get())
          .length;
    }

    final report = await (await engineFor(origin)).sync();
    expect(report.error, isNull);
    expect(report.pending, 0, reason: 'nothing from the import may be unsent');

    final phone = await phoneFor(origin, firmId);

    final phoneBills = await phone.select(phone.purchaseBills).get();
    final phoneInvoices = await phone.select(phone.salesInvoices).get();
    expect(phoneBills, hasLength(purchaseBills.length));
    expect(phoneInvoices, hasLength(salesInvoices.length));

    // A line count, not a spot check: a document can arrive with its header and
    // a plausible total while every one of its rows is missing, and only a
    // per-document count notices.
    final wrong = <String>[];
    for (final bill in phoneBills) {
      final lines = (await (phone.select(phone.purchaseBillItems)
            ..where((t) => t.billId.equals(bill.id)))
          .get())
          .length;
      if (lines != originPurchaseLines[bill.id]) {
        wrong.add('${bill.number}: $lines of ${originPurchaseLines[bill.id]}');
      }
    }
    expect(wrong, isEmpty,
        reason: 'a bill must arrive with the lines it was imported with');

    final salesWrong = <String>[];
    for (final invoice in phoneInvoices) {
      final lines = (await (phone.select(phone.salesInvoiceItems)
            ..where((t) => t.invoiceId.equals(invoice.id)))
          .get())
          .length;
      if (lines != originSalesLines[invoice.id]) {
        salesWrong.add('${invoice.number}: $lines of '
            '${originSalesLines[invoice.id]}');
      }
    }
    expect(salesWrong, isEmpty,
        reason: 'estimates and invoices lose their lines the same way');

    await origin.close();
    await phone.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a full books\' worth of lines survives push and pull', () async {
    // The fixture above is 31 changes — one document's worth. Real books are
    // not: the push splits into batches and the pull replays the journal a page
    // at a time, so nothing about the path is exercised until the journal is
    // bigger than one of each. A bug that only eats the tail of a long journal
    // would pass the small test and still strand a real shop.
    final origin = await booksWith(billCount: 160, linesPerBill: 8);

    final report = await (await engineFor(origin)).sync();
    expect(report.error, isNull);
    expect(report.pending, 0, reason: 'every line must reach the server');
    // More than one batch and more than one page, or the test proves nothing.
    expect(journal.length, greaterThan(SyncEngine.batchSize));
    expect(journal.length, greaterThan(500));

    final firmId = (await origin.select(origin.firms).get()).single.id;
    final phone = await phoneFor(origin, firmId);

    expect(await phone.select(phone.purchaseBills).get(), hasLength(160));
    expect(
      await phone.select(phone.purchaseBillItems).get(),
      hasLength(160 * 8),
      reason: 'every line must arrive',
    );

    await origin.close();
    await phone.close();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a batch the server keeps rejecting is never quietly marked sent',
      () async {
    // Retrying is correct; quarantining is a last resort. `maxAttempts` exists
    // so one impossible row cannot block the queue for ever — but the row must
    // stay *unsent*. Marking it sent claims the server holds a change it never
    // accepted, `pruneSent` then deletes it with the rest of the queue, and
    // the invoice exists on no device at all while the UI reports a clean sync.
    maxBodyBytes = 1; // refuse every push, as an oversized body would
    final origin = AppDatabase.test(NativeDatabase.memory());
    final firm = await origin.firmRepository.create(
      name: 'Mahaveer Computers',
      stateCode: '27',
    );
    await origin.purchaseRepositoryFor(firm.id).save(PurchaseDraft(
      id: 'bill-1',
      number: 'MC/1',
      docType: 'bill',
      billDate: DateTime(2026, 3, 1),
      lines: [
        PurchaseLineDraft(
          id: 'line-1',
          name: 'Charger',
          quantity: Decimal.fromInt(2),
          unit: 'pcs',
          rate: Decimal.fromInt(450),
          gstRate: 18,
        ),
      ],
    ));

    final engine = await engineFor(origin);
    for (var attempt = 1; attempt <= 12; attempt++) {
      await engine.sync();
    }

    final stillQueued = await (origin.select(origin.syncQueue)
          ..where((t) => t.syncedAt.isNull()))
        .get();
    expect(
      stillQueued,
      isNotEmpty,
      reason: 'a change the server never accepted must stay queued and '
          'counted, never marked sent',
    );
    // And it must stop blocking: a quarantined row is out of the drain, so the
    // run terminates rather than retrying for ever.
    expect(
      stillQueued.every((r) => r.attempts >= SyncEngine.maxAttempts),
      isTrue,
      reason: 'a stuck row is held back so it cannot wedge the queue',
    );

    // "Re-send all books" is the recovery, so it has to actually recover.
    await engine.rejournalEverything(firmId: firm.id);
    final afterRepair = await (origin.select(origin.syncQueue)
          ..where((t) => t.syncedAt.isNull()))
        .get();
    expect(
      afterRepair.any((r) => r.attempts < SyncEngine.maxAttempts),
      isTrue,
      reason: 'the repair must put a quarantined row back in the drain',
    );

    await origin.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a document is never delivered without its lines', () async {
    // The reported bug, arranged so the server accepts the *headers* and
    // refuses the *lines*.
    //
    // The drain orders every batch by `journalOrder`, so ALL `purchase_bills`
    // are pushed before ANY `purchase_bill_items`. Counting rows into a batch
    // rather than measuring the encoded body put a whole batch of headers in
    // one request and the far larger lines in requests the server refused
    // whole. The server then held bills with their totals and no items, and any
    // other device pulled exactly that, while the device that imported the
    // backup still showed every line.
    //
    // At least a full batch of bills, so the first request is headers only and
    // the lines land in requests of their own.
    final origin = await booksWith(billCount: 200, linesPerBill: 10);
    final firmId = (await origin.select(origin.firms).get()).single.id;

    final report = await (await engineFor(origin)).sync();
    expect(report.error, isNull);
    expect(report.pending, 0);

    // Every request stayed under the server's cap — that is the fix.
    expect(
      batchSizes.where((size) => size > maxBodyBytes),
      isEmpty,
      reason: 'the client must not build a body the server will refuse: '
          '${batchSizes.where((s) => s > maxBodyBytes).length} of '
          '${batchSizes.length} requests were too large',
    );

    final phone = await phoneFor(origin, firmId);

    expect(
      await phone.select(phone.purchaseBills).get(),
      hasLength(200),
      reason: 'every bill must arrive',
    );
    expect(
      await phone.select(phone.purchaseBillItems).get(),
      hasLength(200 * 10),
      reason: 'a document must not be delivered piecemeal. A bill with a '
          'total and no rows reads as real to a user and to the ledger, so a '
          'torn document is worse than a missing one.',
    );

    await origin.close();
    await phone.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
  test('fresh device discovers books; edits replace retained lines and remove deleted lines', () async {
    final desktop = AppDatabase.test(NativeDatabase.memory());
    final phone = AppDatabase.test(NativeDatabase.memory());
    try {
      final firm = await desktop.firmRepository.create(name: 'Non-GST cloud shop');
      const formats = '{"version":1,"default":"ledger","invoice":"clean","purchase":"business","quotation":"detailed"}';
      await desktop.firmRepository.update(firm.copyWith(pdfTemplate: formats));
      cloudFirmIds.add(firm.id);
      SalesDraft draft({required bool edited}) => SalesDraft(
        id: 'invoice-live', number: 'INV-LIVE', docType: 'invoice',
        invoiceDate: DateTime(2026, 10, 1), lines: [
          SalesLineDraft(id: 'kept', name: 'Goods', quantity: Decimal.fromInt(edited ? 3 : 1),
            unit: 'pcs', rate: Decimal.fromInt(100), gstRate: 18),
          if (!edited) SalesLineDraft(id: 'removed', name: 'Remove this', quantity: Decimal.one,
            unit: 'pcs', rate: Decimal.fromInt(100), gstRate: 18),
        ],
      );
      await desktop.salesRepositoryFor(firm.id).save(draft(edited: false));
      final desktopSync = await engineFor(desktop);
      expect((await desktopSync.sync()).error, isNull);
      final phoneSync = await engineFor(phone);
      expect((await phoneSync.sync()).error, isNull);
      expect((await phone.firmRepository.all()).single.id, firm.id);
      expect((await phone.firmRepository.all()).single.pdfTemplate, formats);
      expect(await phone.salesRepositoryFor(firm.id).itemsFor('invoice-live'), hasLength(2));
      await desktop.salesRepositoryFor(firm.id).save(draft(edited: true));
      expect((await desktopSync.sync()).error, isNull);
      expect((await phoneSync.sync()).error, isNull);
      final lines = await phone.salesRepositoryFor(firm.id).itemsFor('invoice-live');
      expect(lines, hasLength(1));
      expect(lines.single.id, 'kept');
      expect(lines.single.quantity, 3);
      expect(lines.single.total, 300);
      expect((await phone.salesRepositoryFor(firm.id).getById('invoice-live'))!.grandTotal, 300);
      expect((await phoneSync.sync()).error, isNull);
      expect(await phone.salesRepositoryFor(firm.id).itemsFor('invoice-live'), hasLength(1));
    } finally { await desktop.close(); await phone.close(); }
  });

}
