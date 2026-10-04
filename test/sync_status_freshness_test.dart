import 'dart:async';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Settings is a nav-shell branch, so it stays mounted offstage while the shop
/// bills on another tab. A cached "how many changes are waiting" would keep
/// reading zero from the moment the screen was first built — which is wrong in
/// exactly the way that matters, since that number is what tells you the books
/// are not yet safe on the server.

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

  test('the waiting count follows the outbox instead of staying cached',
      () async {
    final firm = await db.firmRepository.create(name: 'Alpha Traders');
    final items = db.itemRepositoryFor(firm.id);

    // Subscribing here is what an open Settings screen does. The firm's own
    // insert row is already queued, so the baseline is not necessarily zero —
    // what matters is that the count moves with the outbox.
    final first = await container.read(syncStatusProvider.future);
    final baseline = first.pending;

    final updated = Completer<SyncStatus>();
    container.listen<AsyncValue<SyncStatus>>(
      syncStatusProvider,
      (_, status) {
        final value = status.valueOrNull;
        if (value != null &&
            value.pending > baseline &&
            !updated.isCompleted) {
          updated.complete(value);
        }
      },
    );

    // A document saved on another tab: Settings does not rebuild, but the
    // outbox grew, so the number it shows has to move with it.
    await items.create(name: 'Steel Rod 12mm');

    final status = await updated.future.timeout(const Duration(seconds: 10));
    expect(status.pending, baseline + 1);
  });

  test('a burst of saves collapses into one re-read', () async {
    final firm = await db.firmRepository.create(name: 'Alpha Traders');
    final items = db.itemRepositoryFor(firm.id);
    await container.read(syncStatusProvider.future);

    final emissions = <int>[];
    container.listen<AsyncValue<SyncStatus>>(
      syncStatusProvider,
      (_, status) {
        final value = status.valueOrNull;
        if (value != null) emissions.add(value.pending);
      },
    );

    // Fifty invoice lines written back to back should not become fifty
    // rebuilds of the settings screen.
    for (var i = 0; i < 10; i++) {
      await items.create(name: 'Item $i');
    }

    // The quiet window is a second, and these ten writes land in well under
    // that, so they should surface as one re-read at the end of the burst
    // rather than one per write. (The bound is loose on purpose: the point is
    // that a burst is not a rebuild per document, not that it is exactly one.)
    // The last count is the firm row plus the ten items.
    await Future.delayed(const Duration(seconds: 3));
    expect(emissions, isNotEmpty);
    expect(emissions.last, 11);
    expect(emissions.length, lessThanOrEqualTo(3),
        reason: 'a burst of saves must not rebuild once per save');
  });
}
