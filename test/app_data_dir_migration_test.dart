import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// The product rename changed the folder the books live in. Everything in that
/// folder is one business's ledger, so "just use a new path" would have opened
/// an empty set of books on every existing install — silently, with no error,
/// and the old ledger still sitting on disk looking authoritative.
///
/// The migration is deliberately a *move* of the whole folder and it runs only
/// while the new folder does not exist. These tests pin both halves of that:
/// the books come across, and nothing that already exists is ever touched.
void main() {
  late Directory support;

  setUp(() {
    support = Directory.systemTemp.createTempSync('apexbooks-data-dir-');
  });

  tearDown(() {
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  Directory legacyDir() => Directory('${support.path}${Platform.pathSeparator}atria');
  Directory newDir() =>
      Directory('${support.path}${Platform.pathSeparator}apexbooks');

  /// Stand in for a populated books folder: the ledger file plus a WAL
  /// sidecar, because the app opens in WAL mode and a real install has both.
  void seedLegacyBooks() {
    final dir = legacyDir()..createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}atria.db').writeAsStringSync('ledger');
    File('${dir.path}${Platform.pathSeparator}atria.db-wal')
        .writeAsStringSync('wal');
  }

  test('a pre-rename books folder is moved across, not copied', () {
    seedLegacyBooks();

    AppDatabase.adoptLegacyDataDir(support.path);

    expect(legacyDir().existsSync(), isFalse,
        reason: 'the old folder must be gone, not left beside the new one');
    expect(newDir().existsSync(), isTrue);

    // Both the ledger and its WAL sidecar have to come across. A migration that
    // moved only the .db would leave the live WAL behind and SQLite would then
    // either refuse to open the database or roll it back to stale pages.
    expect(
      File('${newDir().path}${Platform.pathSeparator}atria.db').readAsStringSync(),
      'ledger',
    );
    expect(
      File('${newDir().path}${Platform.pathSeparator}atria.db-wal')
          .readAsStringSync(),
      'wal',
    );
  });

  test('a books folder that is already there is never overwritten', () {
    seedLegacyBooks();
    final current = newDir()..createSync(recursive: true);
    File('${current.path}${Platform.pathSeparator}apexbooks.db')
        .writeAsStringSync('current-ledger');

    AppDatabase.adoptLegacyDataDir(support.path);

    // This is the case that runs on *every* launch after the first. If the
    // migration were not gated on the new folder being absent, the second
    // launch of a working install would replace its live database with a
    // three-launch-old copy of itself.
    expect(
      File('${current.path}${Platform.pathSeparator}apexbooks.db')
          .readAsStringSync(),
      'current-ledger',
    );
    expect(File('${legacyDir().path}${Platform.pathSeparator}atria.db').existsSync(),
        isTrue,
        reason: 'the older folder must be left intact, not consumed');
  });

  test('an empty leftover folder is not migrated', () {
    legacyDir().createSync(recursive: true);

    AppDatabase.adoptLegacyDataDir(support.path);

    expect(newDir().existsSync(), isFalse,
        reason: 'an empty folder is not a ledger; adopting it would just '
            'inherit the previous failed attempt’s mess');
    expect(legacyDir().existsSync(), isTrue);
  });

  test('a move that cannot happen leaves the books where they were', () {
    seedLegacyBooks();
    // Squat the destination with a file. A directory cannot be renamed onto a
    // file, so the move throws — which is the same failure a cross-volume
    // rename or a locked database produces.
    File('${support.path}${Platform.pathSeparator}apexbooks')
        .writeAsStringSync('not a directory');

    expect(() => AppDatabase.adoptLegacyDataDir(support.path), returnsNormally,
        reason: 'a failed move must not stop the app from starting');
    expect(File('${legacyDir().path}${Platform.pathSeparator}atria.db').existsSync(),
        isTrue,
        reason: 'the books have to still be there to be retried or restored');
  });

  test('a fresh install with no books folder creates the new one on open', () {
    // The counterpart case: nothing to migrate. adoptLegacyDataDir is a no-op
    // and _file() then makes the folder, so a new install is not blocked
    // waiting for a folder that will never arrive.
    AppDatabase.adoptLegacyDataDir(support.path);

    expect(legacyDir().existsSync(), isFalse);
    expect(newDir().existsSync(), isFalse);
  });

  test('the data folder is named for the product, not the old one', () {
    expect(AppDatabase.dataDirName, 'apexbooks');
  });

  group('backup files written before the rename still restore', () {
    Map<String, dynamic> backupWithMarker(Object? marker) => {
          'version': 2,
          'app': marker,
          'exported_at': '2026-01-01T00:00:00.000Z',
          // A minimal but *valid* firm row, so the accepted cases prove the
          // marker is what decided them. A fixture that failed for some other
          // reason would pass for the wrong reason.
          'firms': [
            {'id': 'firm-1', 'name': 'Apex Books Test Firm', 'state_code': '27'},
          ],
          'parties': <dynamic>[],
          'items': <dynamic>[],
          'units': <dynamic>[],
          'categories': <dynamic>[],
          'sales_invoices': <dynamic>[],
          'sales_invoice_items': <dynamic>[],
          'purchase_bills': <dynamic>[],
          'purchase_bill_items': <dynamic>[],
          'payments': <dynamic>[],
          'expenses': <dynamic>[],
          'stock_movements': <dynamic>[],
          'app_settings': <dynamic>[],
          'sync_queue': <dynamic>[],
          'firm_members': <dynamic>[],
        };

    test('a file marked "atria" is accepted', () {
      // The rename changed the marker an export writes. An archive a customer
      // took before upgrading holds exactly the books they would be restoring,
      // so refusing it over a cosmetic string would make every backup taken up
      // to the upgrade worthless on the day it was needed.
      expect(
        () => BackupRepository.validateBackupJson(backupWithMarker('atria')),
        returnsNormally,
      );
    });

    test('a file marked "Apex Books" is accepted', () {
      expect(
        () =>
            BackupRepository.validateBackupJson(backupWithMarker('Apex Books')),
        returnsNormally,
      );
    });

    test('a file from some other app is still refused', () {
      expect(
        () => BackupRepository.validateBackupJson(backupWithMarker('Vyapar')),
        throwsA(isA<FormatException>()),
      );
    });

    test('a file with no marker at all is still refused', () {
      expect(
        () => BackupRepository.validateBackupJson(backupWithMarker(null)),
        throwsA(isA<FormatException>()),
      );
    });
  });
}