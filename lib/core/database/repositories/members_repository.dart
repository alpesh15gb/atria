import 'package:drift/drift.dart';

import '../../domain/member_role.dart';
import '../../utils/id_utils.dart';
import '../app_database.dart';

/// The local users of one firm.
///
/// Separate from `firm_members` being a bare table nobody wrote to: the
/// columns now exist and this is what puts values in them. Nothing here is
/// required — with [AppDatabase.session] off, no member ever signs in and
/// every method below is simply unused.
///
/// **PINs are hashed with a per-member salt and never stored.** [PinHasher]
/// iterates, because a four-digit PIN is about thirteen bits and a single
/// SHA-256 of "1234" is reversible by brute force in well under a second.
class MembersRepository {
  MembersRepository(this.db, this.firmId);

  final AppDatabase db;
  final String firmId;

  static const _hasher = PinHasher();

  Stream<List<FirmMemberEntity>> watchAll() {
    final query = db.select(db.firmMembers)
      ..where((t) => t.firmId.equals(firmId))
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    return query.watch();
  }

  Future<FirmMemberEntity?> byId(String id) {
    return (db.select(
      db.firmMembers,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Everyone a person could sign in as, name plus role — for the picker.
  ///
  /// Deactivated members are excluded: they keep their history, but the
  /// counter must not offer them as a choice.
  Stream<List<FirmMemberEntity>> watchSelectable() {
    final query = db.select(db.firmMembers)
      ..where((t) => t.firmId.equals(firmId) & t.isActive.equals(true))
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    return query.watch();
  }

  Future<FirmMemberEntity> create({
    required String name,
    String? email,
    MemberRole role = MemberRole.staff,
    String? pin,
  }) async {
    db.assertPermission(Permission.manageMasters);
    final id = 'mem_${IdUtils.newId()}';
    final salt = pin == null ? null : PinHasher.newSalt();
    await db
        .into(db.firmMembers)
        .insert(
          FirmMembersCompanion.insert(
            id: id,
            firmId: firmId,
            name: name,
            email: Value(email),
            role: Value(role.name),
            pinHash: Value(pin == null ? null : _hasher.hash(pin, salt!)),
            pinSalt: Value(salt),
          ),
        );
    return (await byId(id))!;
  }

  Future<void> update(
    String id, {
    String? name,
    String? email,
    MemberRole? role,
    bool? isActive,
  }) async {
    db.assertPermission(Permission.manageMasters);
    final current = await byId(id);
    if (current == null) return;
    await (db.update(db.firmMembers)..where((t) => t.id.equals(id))).write(
      FirmMembersCompanion(
        name: name == null ? const Value.absent() : Value(name),
        email: email == null ? const Value.absent() : Value(email),
        role: role == null ? const Value.absent() : Value(role.name),
        isActive: isActive == null ? const Value.absent() : Value(isActive),
      ),
    );
  }

  /// Sets or clears a member's PIN.
  ///
  /// Null clears it, which leaves a member who can still be picked in the
  /// company list but cannot sign in — the honest state for "this person
  /// works here but has no PIN yet".
  Future<void> setPin(String id, String? pin) async {
    db.assertPermission(Permission.manageMasters);
    final salt = pin == null ? null : PinHasher.newSalt();
    await (db.update(db.firmMembers)..where((t) => t.id.equals(id))).write(
      FirmMembersCompanion(
        pinHash: Value(pin == null ? null : _hasher.hash(pin, salt!)),
        pinSalt: Value(salt),
      ),
    );
  }

  /// Removes a member.
  ///
  /// Not a soft delete: a member is not a document, and their audit rows carry
  /// a *name* rather than a foreign key, so removing the row cannot orphan
  /// anything. Anything that referenced them by id does not exist.
  Future<void> delete(String id) async {
    db.assertPermission(Permission.manageMasters);
    await (db.delete(db.firmMembers)..where((t) => t.id.equals(id))).go();
  }

  /// The signed-in session for a member, or null when the PIN is wrong.
  ///
  /// Null rather than a thrown exception, because "wrong PIN" is the expected
  /// outcome of a guess, not an error — the caller re-prompts, and the caller
  /// is the only thing that knows how many attempts to allow.
  ///
  /// A deactivated member cannot sign in even with the right PIN.
  Future<MemberSession?> signIn({
    required String memberId,
    required String pin,
    String? typedName,
  }) async {
    final member = await byId(memberId);
    if (member == null || !member.isActive) return null;
    if (!_hasher.verify(pin, hash: member.pinHash, salt: member.pinSalt)) {
      return null;
    }
    return MemberSession(
      enabled: true,
      memberId: member.id,
      name: member.name,
      role: MemberRole.of(member.role),
      signedInAs: typedName ?? member.name,
    );
  }
}
