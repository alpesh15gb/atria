import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A backup that is not the whole database is worse than a failed export,
/// because the restore reports success. Two things were wrong with the format:
///
/// * the ledger (`accounts`, `journal_entries`, `journal_lines`) and the audit
///   trail were missing, so restoring onto a new device silently dropped every
///   journal voucher and the whole chart of accounts, and restoring over
///   existing books left the previous firms' rows behind as orphans;
/// * the sign-in keys were in it. The export is a plaintext JSON file the
///   backup screen offers to Share, so the access token travelled out of the
///   device, and restoring a colleague's file signed this device in as them.
///
/// `flutter test` cannot run in this environment (the CLI is blocked by an
/// application-control policy), so these assertions are written against the
/// code as read rather than as executed. They are deliberately plain row
/// counts and key sets — no widget, no golden, nothing that would need a
/// device.
void main() {
  late AppDatabase db;
  late BackupRepository backup;
  late SettingsRepository settings;

  /// The `key` values in one settings section of a backup file.
  Set<String> keysOf(dynamic rows) => (rows as List)
      .whereType<Map>()
      .map((row) => row['key'])
      .whereType<String>()
      .toSet();

  /// A firm with a seeded chart, one two-line voucher and an audit trail —
  /// exactly what the export used to leave behind.
  Future<String> seedBooks(AppDatabase target, {String name = 'Balaji'}) async {
    final firm = await target.firmRepository.create(
      name: 'Shri $name Traders',
      stateCode: '29',
    );
    final ledger = target.ledgerRepositoryFor(firm.id);
    await ledger.ensureChart();
    final cash = (await ledger.byCode(LedgerCodes.cash))!;
    final capital = (await ledger.byCode(LedgerCodes.capital))!;
    await ledger.createJournal(
      date: DateTime(2026, 9, 1),
      narration: 'Capital introduced',
      lines: [
        JournalLineDraft(accountId: cash.id, debit: 100000),
        JournalLineDraft(accountId: capital.id, credit: 100000),
      ],
    );
    return firm.id;
  }

  setUp(() {
    db = AppDatabase.test(NativeDatabase.memory());
    backup = db.backupRepository;
    settings = db.settingsRepository;
  });

  tearDown(() => db.close());

  group('export', () {
    test(
      'carries the chart of accounts, the journal and the audit trail',
      () async {
        final firmId = await seedBooks(db);

        final data = await backup.export();
        expect((data['accounts'] as List), isNotEmpty);
        expect((data['journal_entries'] as List), hasLength(1));
        expect((data['journal_lines'] as List), hasLength(2));
        expect((data['audit_logs'] as List), isNotEmpty);

        // Every exported ledger row belongs to an exported firm — an unscoped
        // read is how one firm's vouchers end up in another firm's backup.
        final firmIds = (data['firms'] as List)
            .whereType<Map>()
            .map((row) => row['id'])
            .toSet();
        expect(firmIds, contains(firmId));
        for (final section in ['accounts', 'journal_entries', 'audit_logs']) {
          final owners = (data[section] as List)
              .whereType<Map>()
              .map((row) => row['firm_id'])
              .toSet();
          expect(owners, {firmId}, reason: '$section carried another firm');
        }
      },
    );

    test('never writes the sign-in session into the file', () async {
      final firmId = await seedBooks(db);
      await settings.set(SettingsRepository.kAccessToken, 'live-access-token');
      await settings.set(
        SettingsRepository.kRefreshToken,
        'live-refresh-token',
      );
      await settings.set(
        SettingsRepository.kAccessTokenExpiresAt,
        DateTime.utc(2030).toIso8601String(),
      );
      await settings.set(SettingsRepository.kDeviceId, 'device-abc');
      await settings.set(SettingsRepository.kUserEmail, 'owner@example.com');
      await settings.set(SettingsRepository.kActiveFirmId, firmId);
      await settings.set('receipt_footer', 'Thank you', firmId: firmId);

      // Both scopes: the whole database, and one firm.
      for (final data in [
        await backup.export(),
        await backup.export(firmId: firmId),
      ]) {
        final keys = keysOf(data['settings']);
        for (final key in [
          SettingsRepository.kAccessToken,
          SettingsRepository.kRefreshToken,
          SettingsRepository.kAccessTokenExpiresAt,
          SettingsRepository.kDeviceId,
          SettingsRepository.kUserEmail,
        ]) {
          expect(keys, isNot(contains(key)));
        }
        // …while the books' own settings still travel.
        expect(keys, contains(SettingsRepository.kActiveFirmId));
        expect(keys, contains('receipt_footer'));
      }
    });
  });

  group('restore', () {
    test('brings the ledger across onto an empty device', () async {
      final firmId = await seedBooks(db);
      await settings.set('receipt_footer', 'Thank you', firmId: firmId);
      final data = await backup.export();
      final accountCount = (data['accounts'] as List).length;

      final target = AppDatabase.test(NativeDatabase.memory());
      addTearDown(target.close);
      final restored = await target.backupRepository.importFromJson(data);
      expect(restored, greaterThan(accountCount));

      expect(
        (await target.select(target.firms).get()).map((f) => f.id),
        contains(firmId),
      );

      final accounts = await target.select(target.accounts).get();
      expect(accounts, hasLength(accountCount));
      expect(accounts.every((a) => a.firmId == firmId), isTrue);

      final entries = await target.select(target.journalEntries).get();
      expect(entries, hasLength(1));
      expect(entries.single.narration, 'Capital introduced');
      expect(entries.single.isDeleted, isFalse);

      // The voucher's money survived, not just its shape: still balanced.
      final lines = await target.select(target.journalLines).get();
      expect(lines, hasLength(2));
      expect(
        lines.fold<double>(0, (sum, l) => sum + l.debit),
        lines.fold<double>(0, (sum, l) => sum + l.credit),
      );

      expect(await target.select(target.auditLogs).get(), isNotEmpty);
      expect(
        await target.settingsRepository.get('receipt_footer', firmId: firmId),
        'Thank you',
      );
    });

    test(
      'replacing books leaves no row pointing at a firm that is gone',
      () async {
        await seedBooks(db, name: 'Incoming');
        final data = await backup.export();

        final target = AppDatabase.test(NativeDatabase.memory());
        addTearDown(target.close);
        final doomed = await seedBooks(target, name: 'Doomed');
        await target.settingsRepository.set(
          'receipt_footer',
          'Old books',
          firmId: doomed,
        );
        expect(await target.select(target.accounts).get(), isNotEmpty);

        await target.backupRepository.importFromJson(data);

        // Not "fewer than before" — nothing at all from the firm that is gone.
        final accounts = await target.select(target.accounts).get();
        final entries = await target.select(target.journalEntries).get();
        expect(accounts.any((a) => a.firmId == doomed), isFalse);
        expect(entries.any((e) => e.firmId == doomed), isFalse);
        expect(accounts, isNotEmpty);
        expect(entries, isNotEmpty);

        // …including the lines that hang off those vouchers.
        final entryIds = entries.map((e) => e.id).toSet();
        final lines = await target.select(target.journalLines).get();
        expect(lines.where((l) => !entryIds.contains(l.entryId)), isEmpty);

        // And the settings of the replaced firm go with it.
        expect(
          await target.settingsRepository.get('receipt_footer', firmId: doomed),
          isNull,
        );
      },
    );

    test('every firm-scoped table comes across, not the ones someone remembered', () async {
      // The trap this guards: a table missing from the export list loses all
      // of its data on restore, and nothing anywhere reports it — the restore
      // reports success and the firm simply finds its godowns gone.
      //
      // Rather than assert on the tables we remembered to seed, this asserts
      // that the *export format itself* carries a section for every table in
      // the schema that belongs to a firm. A table added later and forgotten
      // here fails this test the day it is added, not the day somebody needs
      // the data back.
      final firmId = await seedBooks(db);
      await db
          .into(db.godowns)
          .insert(
            GodownsCompanion.insert(
              id: 'godown-1',
              firmId: firmId,
              name: 'Main Store',
              city: const Value('Bengaluru'),
            ),
          );

      final data = await backup.export();

      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%'",
          )
          .get();
      final firmScoped = <String>[];
      for (final table in tables) {
        final name = table.read<String>('name');
        final columns = await db.customSelect('PRAGMA table_info($name)').get();
        if (columns.any((c) => c.read<String>('name') == 'firm_id')) {
          firmScoped.add(name);
        }
      }
      expect(firmScoped, contains('godowns'));

      final sections = data.keys.map((k) => k.toString()).toSet();
      // `app_settings` and `sync_queue` are keyed differently in the file, and
      // `firms` is the anchor everything else hangs off rather than a section
      // of its own.
      final accounted = <String>{'app_settings', 'sync_queue', 'firms'};
      final missing =
          firmScoped
              .where((t) => !sections.contains(t) && !accounted.contains(t))
              .toList()
            ..sort();
      expect(
        missing,
        isEmpty,
        reason: 'these tables are silently dropped on restore: $missing',
      );

      // And the one that matters here actually round-trips.
      final target = AppDatabase.test(NativeDatabase.memory());
      addTearDown(target.close);
      await target.backupRepository.importFromJson(data);
      final godowns = await target.select(target.godowns).get();
      expect(godowns, hasLength(1));
      expect(godowns.single.name, 'Main Store');
      expect(godowns.single.firmId, firmId);
      expect(godowns.single.city, 'Bengaluru');
    });

    test(
      'a backup made before the ledger keys existed still restores',
      () async {
        await seedBooks(db);
        final data = await backup.export();
        // What a v2 file looks like: no ledger sections at all, version 2.
        final legacy = Map<String, dynamic>.from(data)
          ..remove('accounts')
          ..remove('journal_entries')
          ..remove('journal_lines')
          ..remove('audit_logs')
          ..['version'] = 2;

        expect(
          () => BackupRepository.validateBackupJson(legacy),
          returnsNormally,
        );

        final target = AppDatabase.test(NativeDatabase.memory());
        addTearDown(target.close);
        final restored = await target.backupRepository.importFromJson(legacy);
        expect(restored, greaterThan(0));
        expect(await target.select(target.firms).get(), isNotEmpty);
        // Nothing to restore is not a failure — such a file simply says it
        // carries no ledger, and the firm gets seeded on the next open.
        expect(await target.select(target.accounts).get(), isEmpty);
      },
    );

    test('a newer backup is refused before anything is written', () async {
      await seedBooks(db);
      final data = await backup.export();
      await expectLater(
        backup.importFromJson({...data, 'version': 99}),
        throwsA(isA<FormatException>()),
      );
      expect(await db.select(db.accounts).get(), isNotEmpty);
    });

    test(
      "a backup carrying someone else's session does not sign us in",
      () async {
        final firmId = await seedBooks(db);
        await settings.set('receipt_footer', 'Thank you', firmId: firmId);
        final data = await backup.export();

        // A file taken before the export was fixed: the session keys are in it.
        final leaky = Map<String, dynamic>.from(data);
        leaky['settings'] = [
          ...(leaky['settings'] as List),
          {
            'key': SettingsRepository.kAccessToken,
            'firm_id': null,
            'value': 'stolen',
          },
          {
            'key': SettingsRepository.kRefreshToken,
            'firm_id': null,
            'value': 'stolen-refresh',
          },
          {
            'key': SettingsRepository.kAccessTokenExpiresAt,
            'firm_id': null,
            'value': DateTime.utc(2030).toIso8601String(),
          },
          {
            'key': SettingsRepository.kDeviceId,
            'firm_id': null,
            'value': 'other-device',
          },
          {
            'key': SettingsRepository.kUserEmail,
            'firm_id': null,
            'value': 'someone-else@example.com',
          },
        ];

        final target = AppDatabase.test(NativeDatabase.memory());
        addTearDown(target.close);
        await target.backupRepository.importFromJson(leaky);

        final targetSettings = target.settingsRepository;
        for (final key in [
          SettingsRepository.kAccessToken,
          SettingsRepository.kRefreshToken,
          SettingsRepository.kAccessTokenExpiresAt,
          SettingsRepository.kDeviceId,
          SettingsRepository.kUserEmail,
        ]) {
          expect(await targetSettings.get(key), isNull, reason: key);
        }
        // The books themselves are untouched by that filtering.
        expect(
          await targetSettings.get('receipt_footer', firmId: firmId),
          'Thank you',
        );
      },
    );
  });
}
