import 'dart:convert';
import 'dart:io';

import 'package:atria/core/api/api_config.dart';
import 'package:atria/core/api/auth_client.dart';
import 'package:atria/core/api/server_session.dart';
import 'package:atria/core/api/sync_client.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/audit_repository.dart';
import 'package:atria/core/database/repositories/members_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/domain/member_role.dart';
import 'package:atria/core/state/auth_controller.dart';
import 'package:atria/core/sync/sync_engine.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/schema_rollback.dart';

/// Local users and roles: the permission table, the PIN hash, and the guards.
///
/// Three properties are load-bearing and each has its own group below.
///
///  1. **Off means off.** With the session off every permission is granted and
///     every write behaves exactly as it did before this feature shipped. A
///     bug here breaks every existing install, so it is asserted directly
///     rather than inferred.
///  2. **The role table is the policy.** One readable list, so a repository
///     that asks for the wrong permission is caught here.
///  3. **A PIN never leaves the device.** Not in a backup, not on an import,
///     and not recoverable from the stored value.
void main() {
  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    firmId = firm.id;
  });

  tearDown(() async => db.close());

  MembersRepository members() => db.membersRepositoryFor(firmId);

  /// Signs [db] in as [role], which is the whole feature in one line.
  void signInAs(MemberRole role, {String name = 'Priya'}) {
    db.session = MemberSession(
      enabled: true,
      memberId: 'mem_1',
      name: name,
      role: role,
    );
  }

  Future<void> seedParty() async {
    await db.partyRepositoryFor(firmId).create(name: 'Kumar Traders');
  }

  /// A backup envelope that passes validation, so a permission test is not
  /// secretly also asserting that the *format* check fires.
  Map<String, dynamic> backupEnvelope() => {
    'app': 'Apex Books',
    'version': 3,
    'schemaVersion': 12,
    'firms': [
      {'id': firmId, 'name': 'Apex Integrations'},
    ],
  };

  group('the session itself', () {
    test(
      'off grants every permission, because there is nobody to restrict',
      () {
        for (final permission in Permission.values) {
          expect(
            MemberSession.off.allows(permission),
            isTrue,
            reason: '$permission must be granted while the feature is off',
          );
        }
      },
    );

    test(
      'an unreadable role resolves to the least privilege, not the most',
      () {
        // Least, because the failure mode of "most" is a shop quietly granting
        // an accountant the ability to empty the recycle bin.
        expect(MemberRole.of('superuser'), MemberRole.accountant);
        expect(MemberRole.of(null), MemberRole.accountant);
        expect(MemberRole.of(''), MemberRole.accountant);
        expect(MemberRole.of('admin'), MemberRole.admin);
      },
    );

    test('admin holds every permission the app knows about', () {
      for (final permission in Permission.values) {
        expect(
          MemberRole.admin.allows(permission),
          isTrue,
          reason: 'admin must hold $permission',
        );
      }
    });

    test(
      'staff can sell but cannot void, delete or re-open a locked period',
      () {
        const staff = MemberRole.staff;
        expect(staff.allows(Permission.createSales), isTrue);
        expect(staff.allows(Permission.createPurchases), isTrue);
        expect(staff.allows(Permission.recordPayment), isTrue);
        // The line the role is named for.
        expect(staff.allows(Permission.cancelDocument), isFalse);
        expect(staff.allows(Permission.softDelete), isFalse);
        expect(staff.allows(Permission.purge), isFalse);
        expect(staff.allows(Permission.managePeriodLock), isFalse);
        expect(staff.allows(Permission.restoreBackup), isFalse);
        expect(staff.allows(Permission.deleteBusiness), isFalse);
      },
    );

    test('accountant can read and export, and write nothing at all', () {
      const accountant = MemberRole.accountant;
      expect(accountant.allows(Permission.view), isTrue);
      expect(accountant.allows(Permission.export), isTrue);
      for (final permission in Permission.values) {
        if (permission == Permission.view || permission == Permission.export) {
          continue;
        }
        expect(
          accountant.allows(permission),
          isFalse,
          reason: 'accountant must not hold $permission',
        );
      }
    });

    test('a signed-in session with no role grants nothing extra', () {
      // Reachable only if a role string fails to resolve at the session level.
      // Defaulting to permissive there would undo the whole point of the
      // per-member resolution above.
      const session = MemberSession(enabled: true, memberId: 'm');
      expect(session.allows(Permission.purge), isFalse);
      expect(session.allows(Permission.createSales), isFalse);
    });
  });

  group('repository guards', () {
    test(
      'a refused write throws PermissionDeniedException carrying the cause',
      () async {
        signInAs(MemberRole.accountant);
        await expectLater(
          db.partyRepositoryFor(firmId).create(name: 'Kumar Traders'),
          throwsA(
            isA<PermissionDeniedException>()
                .having(
                  (e) => e.permission,
                  'permission',
                  Permission.manageMasters,
                )
                .having((e) => e.role, 'role', MemberRole.accountant),
          ),
        );
      },
    );

    test('an accountant cannot record a payment', () async {
      signInAs(MemberRole.accountant);
      await expectLater(
        db
            .paymentRepositoryFor(firmId)
            .create(
              type: 'payment_in',
              number: 'RCPT/1',
              amount: 100,
              date: DateTime(2026, 10, 1),
            ),
        throwsA(
          isA<PermissionDeniedException>().having(
            (e) => e.permission,
            'permission',
            Permission.recordPayment,
          ),
        ),
      );
    });

    test('staff can create a master but cannot delete one', () async {
      signInAs(MemberRole.staff);
      final party = await db
          .partyRepositoryFor(firmId)
          .create(name: 'Kumar Traders');
      // Created, so the role can do this much.
      expect(party.name, 'Kumar Traders');

      await expectLater(
        db.partyRepositoryFor(firmId).delete(party.id),
        throwsA(
          isA<PermissionDeniedException>().having(
            (e) => e.permission,
            'permission',
            Permission.softDelete,
          ),
        ),
      );
    });

    test('a refused write leaves the row unwritten', () async {
      signInAs(MemberRole.accountant);
      try {
        await db.itemRepositoryFor(firmId).create(name: 'Widget');
      } on PermissionDeniedException {
        // Expected; the point is what is left behind afterwards.
      }
      expect(await db.itemRepositoryFor(firmId).all(), isEmpty);
    });

    test(
      'an accountant cannot permanently delete a master from the bin',
      () async {
        // Delete-forever is a *different* permission from soft delete, and a
        // role could hold one without the other. Asserting both means a future
        // edit to either set shows up here rather than in production.
        final item = await db.itemRepositoryFor(firmId).create(name: 'Widget');
        await db.itemRepositoryFor(firmId).delete(item.id);
        signInAs(MemberRole.accountant);
        await expectLater(
          db.itemRepositoryFor(firmId).deleteForever(item.id),
          throwsA(
            isA<PermissionDeniedException>().having(
              (e) => e.permission,
              'permission',
              Permission.purge,
            ),
          ),
        );
        // Still in the bin, not destroyed.
        final binned = await db.itemRepositoryFor(firmId).watchDeleted().first;
        expect(binned.map((i) => i.id), contains(item.id));
      },
    );

    test('an accountant cannot re-send the books to the server', () async {
      // Rejournaling is the one write that re-queues every row the firm has.
      //
      // Built by hand rather than through `syncEngineProvider` so no server
      // session is involved. The `AuthController` constructor kicks off a
      // token refresh, but with no token stored it resolves to "not signed in"
      // from local settings alone and never reaches the network — and the
      // permission guard is the first statement in the method regardless, so
      // nothing below it runs.
      signInAs(MemberRole.accountant);
      final settings = db.settingsRepository;
      final engine = SyncEngine(
        db,
        settings,
        AuthController(
          ServerSession(settings),
          AuthClient(ApiConfig(settings)),
        ),
        SyncClient(ApiConfig(settings)),
      );
      await expectLater(
        engine.rejournalEverything(firmId: firmId),
        throwsA(
          isA<PermissionDeniedException>().having(
            (e) => e.permission,
            'permission',
            Permission.sync,
          ),
        ),
      );
    });

    test(
      'the period lock refuses to move for staff, in both directions',
      () async {
        final lock = PeriodLock(db.settingsRepository);
        signInAs(MemberRole.staff);
        await expectLater(
          lock.lockThrough(DateTime(2026, 3, 31), firmId: firmId),
          throwsA(
            isA<PermissionDeniedException>().having(
              (e) => e.permission,
              'permission',
              Permission.managePeriodLock,
            ),
          ),
        );
        await expectLater(
          lock.unlock(firmId: firmId),
          throwsA(
            isA<PermissionDeniedException>().having(
              (e) => e.permission,
              'permission',
              Permission.managePeriodLock,
            ),
          ),
        );
        // Nothing was written, in either direction.
        expect(await lock.lockedUpto(firmId: firmId), isNull);
      },
    );

    test('an admin can move the period lock', () async {
      final lock = PeriodLock(db.settingsRepository);
      signInAs(MemberRole.admin);
      await lock.lockThrough(DateTime(2026, 3, 31), firmId: firmId);
      expect(await lock.lockedUpto(firmId: firmId), DateTime(2026, 3, 31));
      await lock.unlock(firmId: firmId);
      expect(await lock.lockedUpto(firmId: firmId), isNull);
    });

    test(
      'an accountant cannot restore a backup, which replaces everything',
      () async {
        signInAs(MemberRole.accountant);
        await expectLater(
          db.backupRepository.importFromJson(backupEnvelope()),
          throwsA(
            isA<PermissionDeniedException>().having(
              (e) => e.permission,
              'permission',
              Permission.restoreBackup,
            ),
          ),
        );
      },
    );

    test('an accountant cannot remove the business', () async {
      signInAs(MemberRole.accountant);
      await expectLater(
        db.firmRepository.purge(firmId),
        throwsA(
          isA<PermissionDeniedException>().having(
            (e) => e.permission,
            'permission',
            Permission.deleteBusiness,
          ),
        ),
      );
      // Still here.
      expect(await db.firmRepository.getById(firmId), isNotNull);
    });

    test('an accountant cannot empty the recycle bin', () async {
      // Seed and bin the row with no session, then sign in: the accountant must
      // be refused the *purge*, not the setup.
      await seedParty();
      final party = await db.partyRepositoryFor(firmId).all();
      await db.partyRepositoryFor(firmId).delete(party.first.id);
      signInAs(MemberRole.accountant);
      await expectLater(
        db.partyRepositoryFor(firmId).deleteForever(party.first.id),
        throwsA(
          isA<PermissionDeniedException>().having(
            (e) => e.permission,
            'permission',
            Permission.purge,
          ),
        ),
      );
    });

    test('the guard is checked before the transaction opens', () async {
      // A permission check that runs inside a transaction is still correct, but
      // it cannot fail for a row that does not exist: the refusal would come
      // after the read. Asserting the throw alone would not notice the
      // difference, so check the *other* half — a non-existent id is still
      // refused rather than silently returning.
      signInAs(MemberRole.accountant);
      await expectLater(
        db.partyRepositoryFor(firmId).restore('pty_does_not_exist'),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('with the session off every guarded write still works', () async {
      // The "off is indistinguishable from before" property, on the write path
      // rather than on the enum.
      db.session = MemberSession.off;
      final party = await db
          .partyRepositoryFor(firmId)
          .create(name: 'Kumar Traders');
      await db.partyRepositoryFor(firmId).delete(party.id);
      await db.partyRepositoryFor(firmId).restore(party.id);
      await db.firmRepository.purge(firmId);
      expect(await db.firmRepository.getById(firmId), isNull);
    });
  });

  group('members and PINs', () {
    test('a member is created with a role and no PIN at all', () async {
      final created = await members().create(
        name: 'Priya',
        role: MemberRole.staff,
      );
      expect(created.role, MemberRole.staff.name);
      expect(created.isActive, isTrue);
      // No hash, no salt — not a hash of the empty string, which would have
      // been a PIN that nobody chose and everybody could guess.
      expect(created.pinHash, isNull);
      expect(created.pinSalt, isNull);
    });

    test('a PIN is never stored, only a salted hash', () async {
      final created = await members().create(name: 'Priya', pin: '1234');
      expect(created.pinHash, isNotNull);
      expect(created.pinHash, isNot('1234'));
      expect(created.pinSalt, isNotNull);
      // Not recoverable by hashing the obvious way either.
      expect(created.pinHash, isNot(contains('1234')));
    });

    test('the same PIN under two members gives two different hashes', () async {
      // The point of a per-member salt: identical digests would let one
      // member's stolen hash be replayed against another's account.
      final a = await members().create(name: 'A', pin: '1234');
      final b = await members().create(name: 'B', pin: '1234');
      expect(a.pinSalt, isNot(b.pinSalt));
      expect(a.pinHash, isNot(b.pinHash));
    });

    test('the right PIN signs in, and returns the member\'s role', () async {
      final created = await members().create(
        name: 'Priya',
        role: MemberRole.accountant,
        pin: '4821',
      );
      final session = await members().signIn(memberId: created.id, pin: '4821');
      expect(session, isNotNull);
      expect(session!.role, MemberRole.accountant);
      expect(session.memberId, created.id);
      expect(session.signedInAs, 'Priya');
      expect(session.enabled, isTrue);
    });

    test('the wrong PIN signs nobody in', () async {
      final created = await members().create(name: 'Priya', pin: '4821');
      expect(await members().signIn(memberId: created.id, pin: '4822'), isNull);
      // A short PIN is not a prefix match.
      expect(await members().signIn(memberId: created.id, pin: '482'), isNull);
      expect(
        await members().signIn(memberId: created.id, pin: '482133'),
        isNull,
      );
    });

    test('a member with no PIN cannot sign in at all', () async {
      // Otherwise "no PIN" would be a universal PIN.
      final created = await members().create(name: 'Priya');
      expect(await members().signIn(memberId: created.id, pin: ''), isNull);
      expect(await members().signIn(memberId: created.id, pin: '0000'), isNull);
    });

    test(
      'a deactivated member cannot sign in even with the right PIN',
      () async {
        final created = await members().create(name: 'Priya', pin: '4821');
        await members().update(created.id, isActive: false);
        expect(
          await members().signIn(memberId: created.id, pin: '4821'),
          isNull,
        );
      },
    );

    test('changing the PIN invalidates the old one', () async {
      final created = await members().create(name: 'Priya', pin: '4821');
      await members().setPin(created.id, '9999');
      expect(await members().signIn(memberId: created.id, pin: '4821'), isNull);
      expect(
        await members().signIn(memberId: created.id, pin: '9999'),
        isNotNull,
      );
    });

    test('clearing the PIN locks the member out', () async {
      final created = await members().create(name: 'Priya', pin: '4821');
      await members().setPin(created.id, null);
      expect(await members().signIn(memberId: created.id, pin: '4821'), isNull);
      expect((await members().byId(created.id))!.pinHash, isNull);
    });

    test('the picker offers only active members', () async {
      final a = await members().create(name: 'A', pin: '1111');
      await members().create(name: 'B', pin: '2222');
      final c = await members().create(name: 'C', pin: '3333');
      await members().update(c.id, isActive: false);

      final selectable = await members().watchSelectable().first;
      expect(selectable.map((m) => m.name), isNot(contains('C')));
      // The roster still holds them — a deactivated member is kept for the
      // audit trail, not deleted.
      final all = await members().watchAll().first;
      expect(all.map((m) => m.name), contains('C'));
      expect(all.map((m) => m.name), contains('A'));
      expect(a.isActive, isTrue);
    });

    test('the manager needs manageMasters to add anyone', () async {
      signInAs(MemberRole.accountant);
      await expectLater(
        members().create(name: 'Intruder'),
        throwsA(
          isA<PermissionDeniedException>().having(
            (e) => e.permission,
            'permission',
            Permission.manageMasters,
          ),
        ),
      );
      expect(await members().watchAll().first, isEmpty);
    });
  });

  group('PinHasher', () {
    const hasher = PinHasher(iterations: 100);

    test('verify accepts the PIN it hashed and rejects everything else', () {
      final salt = PinHasher.newSalt();
      final hash = hasher.hash('4821', salt);
      expect(hasher.verify('4821', hash: hash, salt: salt), isTrue);
      expect(hasher.verify('4822', hash: hash, salt: salt), isFalse);
      expect(hasher.verify('', hash: hash, salt: salt), isFalse);
    });

    test('the salt is mixed in, so the same PIN hashes differently', () {
      final a = hasher.hash('4821', PinHasher.newSalt());
      final b = hasher.hash('4821', PinHasher.newSalt());
      expect(a, isNot(b));
    });

    test('a hash cannot be verified under a different salt', () {
      final salt = PinHasher.newSalt();
      final hash = hasher.hash('4821', salt);
      expect(
        hasher.verify('4821', hash: hash, salt: PinHasher.newSalt()),
        isFalse,
      );
    });

    test('a null hash or salt verifies as false rather than throwing', () {
      // The "no PIN set" case has to be a refusal, not a crash on the counter.
      expect(hasher.verify('4821', hash: null, salt: 'x'), isFalse);
      expect(hasher.verify('4821', hash: 'x', salt: null), isFalse);
      expect(hasher.verify('4821', hash: null, salt: null), isFalse);
    });

    test('a hash of a different length is rejected before comparison', () {
      final salt = PinHasher.newSalt();
      expect(
        hasher.verify(
          '4821',
          hash: '${hasher.hash('4821', salt)}x',
          salt: salt,
        ),
        isFalse,
      );
    });
  });

  group('a PIN never reaches a backup', () {
    test('the exported JSON carries no hash and no salt', () async {
      await members().create(name: 'Priya', pin: '4821');
      await members().create(name: 'Ravi', role: MemberRole.admin, pin: '9999');
      final json = await db.backupRepository.export();
      final text = jsonEncode(json);
      expect(text, isNot(contains('pin_hash')));
      expect(text, isNot(contains('pin_salt')));
      // And the raw values, in case the column names ever change.
      final member = (await members().watchAll().first).firstWhere(
        (m) => m.name == 'Priya',
      );
      expect(text, isNot(contains(member.pinHash!)));
      expect(text, isNot(contains(member.pinSalt!)));
    });

    test('the roster itself still exports, minus the secrets', () async {
      // Stripping the columns must not silently strip the members: they are
      // real business data and the operator expects them in the file.
      await members().create(name: 'Priya', pin: '4821');
      final exported = await db.backupRepository.export();
      expect(exported['firm_members'], isNotNull);
      final rows = exported['firm_members'] as List;
      expect(rows, hasLength(1));
      final row = (rows.first as Map).cast<String, Object?>();
      expect(row['name'], 'Priya');
      expect(row['role'], MemberRole.staff.name);
      expect(row.containsKey('pin_hash'), isFalse);
      expect(row.containsKey('pin_salt'), isFalse);
    });

    test(
      'restoring a hand-edited file that contains a hash does not write it',
      () async {
        // The import path must strip as well as the export path. A file someone
        // edited in a text editor, or one from a future build that did export
        // the columns, must not be able to plant a hash.
        final backup = {
          ...backupEnvelope(),
          'firm_members': [
            {
              'id': 'mem_forged',
              'firm_id': firmId,
              'name': 'Forged',
              'role': MemberRole.admin.name,
              'user_id': null,
              'created_at': DateTime(2026, 1, 1).toIso8601String(),
              'pin_hash': 'planted-hash',
              'pin_salt': 'planted-salt',
              'is_active': true,
            },
          ],
        };
        signInAs(MemberRole.admin);
        await db.backupRepository.importFromJson(backup);

        final imported = await members().byId('mem_forged');
        expect(imported, isNotNull);
        expect(imported!.name, 'Forged');
        expect(imported.pinHash, isNull);
        expect(imported.pinSalt, isNull);
      },
    );
  });

  group('the v10 migration', () {
    test(
      'an existing member row survives and picks up the new defaults',
      () async {
        final dir = await Directory.systemTemp.createTemp('atria_v10');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/books.db');

        // 1. Write a file at the current version and add a member by hand.
        final first = AppDatabase.test(NativeDatabase(file));
        final firm = await first.firmRepository.create(name: 'Apex');
        await first
            .into(first.firmMembers)
            .insert(
              FirmMembersCompanion.insert(
                id: 'mem_legacy',
                firmId: firm.id,
                name: 'Existing member',
                role: Value('admin'),
              ),
            );
        await first.close();

        // 2. Roll back to what a v9 file looked like: the three columns this
        //    migration adds are the ones a real v9 file would not have.
        final rolled = AppDatabase.test(NativeDatabase(file));
        await rolled.customStatement(
          'ALTER TABLE firm_members DROP COLUMN pin_hash',
        );
        await rolled.customStatement(
          'ALTER TABLE firm_members DROP COLUMN pin_salt',
        );
        await rolled.customStatement(
          'ALTER TABLE firm_members DROP COLUMN is_active',
        );
        // v11's and v12's columns too — the chain runs v9 → v10 → v11 → v12,
        // and leaving them in place makes a later step fail on a duplicate
        // column, which reads as a broken migration rather than a stale
        // rollback list.
        await SchemaRollback.bankingV12(rolled);
        await SchemaRollback.costingV11(rolled);
        await SchemaRollback.setVersion(rolled, 9);
        await rolled.close();

        // 3. Reopen: the v9 -> v10, v10 -> v11 and v11 -> v12 upgrades run for
        //    real.
        final upgraded = AppDatabase.test(NativeDatabase(file));
        addTearDown(upgraded.close);
        expect(upgraded.schemaVersion, 14);

        final member = await upgraded
            .membersRepositoryFor(firm.id)
            .byId('mem_legacy');
        expect(member, isNotNull);
        expect(member!.name, 'Existing member');
        // The defaults, and specifically no PIN invented for someone who never
        // chose one.
        expect(member.isActive, isTrue);
        expect(member.pinHash, isNull);
        expect(member.pinSalt, isNull);
      },
    );
  });
}
