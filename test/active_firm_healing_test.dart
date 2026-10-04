import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The active firm must heal when its row disappears from underneath it.

/// The local deletion path repoints it itself. The sync pull does not: a firm
/// erased on another device arrives as a tombstone, `PullApplier` hard-deletes
/// the row, and nothing cleared the stored id — so this device kept rendering a
/// phantom, zeroed business (every firm-scoped repository stays non-null while
/// the id is set) that the switcher no longer listed, with no way back but a
/// relaunch. The controller now watches the row it selected and applies the
/// same policy as the local path.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<String> seedFirm(String name, {bool isDefault = false}) async {
    final firm = await db.firmRepository.create(name: name);
    if (isDefault) {
      await db.firmRepository.setDefault(firm.id);
    }
    return firm.id;
  }

  test('repoints to the default firm when the active one is deleted underneath',
      () async {
    final defaultId = await seedFirm('Alpha Traders', isDefault: true);
    final activeId = await seedFirm('Beta Supplies');
    // The boot gate resolves init before any UI can pick a firm.
    await container.read(activeFirmIdProvider.notifier).ready;
    await container.read(activeFirmIdProvider.notifier).select(activeId);

    // The sync path: a tombstone deletes the row outright, no repoint.
    await db.customUpdate(
      'DELETE FROM firms WHERE id = ?',
      variables: [Variable.withString(activeId)],
      updates: {db.firms},
    );
    // The watch is a stream; let drift emit.
    await Future.delayed(const Duration(milliseconds: 300));

    expect(container.read(activeFirmIdProvider), defaultId,
        reason: 'the open firm died, so the default takes over');
    final stored =
        await container.read(settingsRepositoryProvider).get('active_firm_id');
    expect(stored, defaultId,
        reason: 'the dead id must not survive into the next launch');
  });

  test('clears the active firm when the last business is deleted', () async {
    final onlyId = await seedFirm('Solo Business', isDefault: true);
    await container.read(activeFirmIdProvider.notifier).ready;
    await container.read(activeFirmIdProvider.notifier).select(onlyId);

    await db.customUpdate(
      'DELETE FROM firms WHERE id = ?',
      variables: [Variable.withString(onlyId)],
      updates: {db.firms},
    );
    await Future.delayed(const Duration(milliseconds: 300));

    expect(container.read(activeFirmIdProvider), isNull);
    expect(container.read(reportRepositoryProvider), isNull,
        reason: 'no firm scoped, so no repository should resolve');
  });

  test('a firm deleted while another is active does not disturb the open one',
      () async {
    final activeId = await seedFirm('Alpha Traders', isDefault: true);
    final otherId = await seedFirm('Beta Supplies');
    await container.read(activeFirmIdProvider.notifier).ready;
    await container.read(activeFirmIdProvider.notifier).select(activeId);

    await db.customUpdate(
      'DELETE FROM firms WHERE id = ?',
      variables: [Variable.withString(otherId)],
      updates: {db.firms},
    );
    await Future.delayed(const Duration(milliseconds: 300));

    expect(container.read(activeFirmIdProvider), activeId,
        reason: 'an unrelated deletion must not move the open books');
  });
}
