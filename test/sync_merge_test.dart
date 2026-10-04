import 'package:atria/core/api/sync_client.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/sync/pull_applier.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pull half's merge rule decides which device's copy of a row survives,
/// and every way it can be wrong is silent: the books look complete, the sync
/// reports success, and one device's edit is simply never seen again. These
/// three cases are the ones the rule turns on — equal stamps, a local stamp
/// plausibly ahead, and a local stamp absurdly ahead — applied directly rather
/// than through a server, because the outcome is a decision about two
/// timestamps and nothing else.
void main() {
  late AppDatabase db;
  late String firmId;
  late PullApplier applier;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Shri Balaji Traders',
      stateCode: '29',
    );
    firmId = firm.id;
    applier = PullApplier(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// A party row from another device, in the shape the push sends: the whole
  /// row, with drift's seconds normalised out to milliseconds.
  Map<String, Object?> partyPayload(
    String id,
    String name, {
    required DateTime updatedAt,
  }) =>
      {
        'id': id,
        'firm_id': firmId,
        'name': name,
        'type': 'customer',
        'phone': null,
        'is_deleted': false,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  /// Applies one pulled party write to [id] and returns the name it left.
  ///
  /// [applied] pins whether the applier claimed the row or declined it, because
  /// a refusal is the interesting half of each case and not looking at it
  /// would let both tests pass on the same no-op.
  Future<String> pullOnto(
    String id,
    String name, {
    required DateTime updatedAt,
    required bool applied,
  }) async {
    final report = await applier.applyPage(
      firmId: firmId,
      page: PullPage(
        changes: [
          JournaledChange(
            seq: 1,
            changeId: 'change-$id',
            entity: 'parties',
            entityId: id,
            operation: 'update',
            payload: partyPayload(id, name, updatedAt: updatedAt),
          ),
        ],
        hasMore: false,
      ),
    );
    expect(report.applied, applied ? 1 : 0);
    expect(report.skipped, applied ? 0 : 1);
    final row = await (db.select(db.parties)..where((t) => t.id.equals(id)))
        .getSingle();
    return row.name;
  }

  test('a same-second write from another device is not thrown away',
      () async {
    final local = await db.partyRepositoryFor(firmId).create(name: 'Local');
    final row = await (db.select(db.parties)..where((t) => t.id.equals(local.id)))
        .getSingle();

    // The two devices saved inside one second, so drift's second-truncated
    // stamps are identical and there is no ordering left to compare. The old
    // rule read "not newer" as "older" and refused this — and because the
    // cursor advances past a refused row, the edit was never re-fetched.
    final name = await pullOnto(
      local.id,
      'Remote same second',
      updatedAt: row.updatedAt,
      applied: true,
    );

    expect(name, 'Remote same second');
  });

  test('a genuinely newer local write still wins', () async {
    final local = await db.partyRepositoryFor(firmId).create(name: 'Local');
    // The local copy was written two hours after the pulled one — a plausible
    // edit, inside the skew the rule is willing to believe.
    final stamp = DateTime.now().toUtc().add(const Duration(hours: 2));
    await db.customUpdate(
      'UPDATE parties SET updated_at = ? WHERE id = ?',
      variables: [Variable.withDateTime(stamp), Variable.withString(local.id)],
      updates: {db.parties},
    );

    final name = await pullOnto(
      local.id,
      'Remote older',
      updatedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
      applied: false,
    );

    expect(name, 'Local');
  });

  test('a local clock far ahead does not win for ever', () async {
    final local = await db.partyRepositoryFor(firmId).create(name: 'Local');
    // Six years of skew: no edit happens six years apart from a correct clock,
    // so this is a clock, and an unbounded comparison would let this device
    // overwrite the other one's real work every single time.
    final stamp = DateTime.now().toUtc().add(const Duration(days: 365 * 6));
    await db.customUpdate(
      'UPDATE parties SET updated_at = ? WHERE id = ?',
      variables: [Variable.withDateTime(stamp), Variable.withString(local.id)],
      updates: {db.parties},
    );

    final name = await pullOnto(
      local.id,
      'Remote genuine edit',
      updatedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
      applied: true,
    );

    expect(name, 'Remote genuine edit');
  });
}