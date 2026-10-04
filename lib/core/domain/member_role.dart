import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// What a local member is allowed to do.
///
/// The permission set lives here rather than in the repositories so the whole
/// policy is one readable list. Repositories ask [allows]; they never
/// hard-code a role name, because a `role == 'admin'` check scattered across
/// eleven writes is a policy nobody can review and nobody can change.
///
/// **Deliberately coarse.** This is a PIN for a shop counter, not an identity
/// provider. It is not a substitute for real accounts, and it is not claimed to
/// be: a determined person with the device in their hands can read the
/// database, and the hash below slows that without pretending to stop it.
enum MemberRole {
  /// Everything, including the destructive and whole-books operations.
  admin('Admin'),

  /// Day-to-day selling, but cannot void, delete, or re-open a locked period.
  staff('Staff'),

  /// Read-only plus reports. Cannot write anything at all.
  accountant('Accountant');

  const MemberRole(this.label);

  final String label;

  /// Resolves a stored role, defaulting to the **least** privilege.
  ///
  /// Least, not most: an unreadable value must not silently become an admin.
  /// A member whose role was written by a newer build, or hand-edited, gets
  /// the narrowest set — the operator can fix it, but nobody is quietly granted
  /// the ability to empty the recycle bin.
  static MemberRole of(String? raw) {
    for (final role in MemberRole.values) {
      if (role.name == raw) return role;
    }
    return MemberRole.accountant;
  }

  /// The permissions this role holds.
  Set<Permission> get permissions => switch (this) {
    MemberRole.admin => Permission.values.toSet(),
    MemberRole.staff => {
      Permission.view,
      Permission.createSales,
      Permission.createPurchases,
      Permission.recordPayment,
      // Masters, deliberately. A person at the counter who cannot add a
      // customer cannot sell to a new customer, and that is not "day-to-day
      // selling" — it makes the role useless at the exact moment it is needed,
      // and pushes the work to an admin standing somewhere else. Deleting a
      // master is a separate permission and is not in this set.
      Permission.manageMasters,
      Permission.print,
      Permission.export,
    },
    MemberRole.accountant => {Permission.view, Permission.export},
  };

  bool allows(Permission permission) => permissions.contains(permission);
}

/// The individual acts a role can be refused.
enum Permission {
  /// Read anything in the books.
  view,

  /// Save invoices, quotations and the documents derived from them.
  createSales,

  /// Save bills, purchase orders and the documents derived from them.
  createPurchases,

  /// Record money in and out against a document.
  recordPayment,

  /// Cancel a document — voids it and reverses its effect.
  cancelDocument,

  /// Move a document to the recycle bin, and restore one out of it.
  softDelete,

  /// Delete a document permanently, or empty the whole bin.
  purge,

  /// Change a period lock, in either direction.
  managePeriodLock,

  /// Create, edit and delete masters — parties, items, accounts.
  manageMasters,

  /// Restore a backup, which replaces every firm's data.
  restoreBackup,

  /// Remove the business itself.
  deleteBusiness,

  /// Print or share any document.
  print,

  /// Export anything to CSV or PDF.
  export,

  /// Push books to the server.
  sync,
}

/// The person currently signed in at the counter, and whether anyone is.
///
/// **Off by default, and "off" is the absence of this object.** The whole
/// feature is gated on [enabled]: with it off there is no gate, no picker and
/// no permission consulted, and every write behaves exactly as it did before
/// local users existed. That is the only way to be confident an opt-in safety
/// feature does not change the app for the people who did not ask for it.
class MemberSession {
  const MemberSession({
    required this.enabled,
    this.memberId,
    this.name,
    this.role,
    this.signedInAs,
  });

  /// Local users turned on for this firm. When false, [MemberSession.current]
  /// is `null` and every permission is granted.
  final bool enabled;

  final String? memberId;
  final String? name;
  final MemberRole? role;

  /// How the person identified themselves — the name they typed before the
  /// PIN, which need not match a member record. Kept for the audit trail: a
  /// wrong PIN still produces a session, because refusing the whole operation
  /// is not the same as knowing who tried.
  final String? signedInAs;

  bool get isSignedIn => enabled && memberId != null;

  /// Whether this session may do [permission].
  ///
  /// Three cases, and the third is the one that is easy to get backwards.
  ///
  /// * **Off** — grants everything. This is the whole "opt-in" promise: a firm
  ///   that never turned the feature on is not running with a null role that
  ///   happens to be permissive, it is running with no session at all.
  /// * **On, with a role** — asks the role.
  /// * **On, with no role** — denies. Unreachable through the sign-in path
  ///   ([MembersRepository.signIn] resolves a role or returns null), so this is
  ///   the guard for a session assembled some other way. Defaulting it to
  ///   permissive would make a missing role a universal key, and the one thing
  ///   the feature must never do is fail *open*.
  bool allows(Permission permission) {
    if (!enabled) return true;
    return role?.allows(permission) ?? false;
  }

  MemberSession as(MemberRole next) => MemberSession(
    enabled: enabled,
    memberId: memberId,
    name: name,
    role: next,
    signedInAs: signedInAs,
  );

  static const MemberSession off = MemberSession(enabled: false);

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'memberId': memberId,
    'name': name,
    'role': role?.name,
    'signedInAs': signedInAs,
  };
}

/// Thrown when a member's role does not permit the operation.
///
/// Carries the permission and the role so the caller can say *why* without
/// string-matching a message, and so a test can assert on the cause rather
/// than on prose.
class PermissionDeniedException implements Exception {
  PermissionDeniedException(this.permission, {this.role, this.memberName});

  final Permission permission;
  final MemberRole? role;
  final String? memberName;

  String get message {
    final who = memberName ?? role?.label ?? 'This user';
    return '$who is not allowed to ${_verb(permission)}. '
        'Ask an admin to change the role in Settings.';
  }

  /// "void a document", "empty the recycle bin" — a permission name is a
  /// constant, not a sentence.
  static String _verb(Permission permission) => switch (permission) {
    Permission.view => 'view the books',
    Permission.createSales => 'create sales documents',
    Permission.createPurchases => 'create purchase documents',
    Permission.recordPayment => 'record payments',
    Permission.cancelDocument => 'cancel documents',
    Permission.softDelete => 'delete documents',
    Permission.purge => 'delete documents permanently',
    Permission.managePeriodLock => 'change period locks',
    Permission.manageMasters => 'edit masters',
    Permission.restoreBackup => 'restore backups',
    Permission.deleteBusiness => 'remove the business',
    Permission.print => 'print documents',
    Permission.export => 'export',
    Permission.sync => 'sync',
  };

  @override
  String toString() => message;
}

/// Salted PIN hashing.
///
/// Iterated because a four-digit PIN has ~13 bits of entropy — a single
/// SHA-256 of "1234" is invertible by brute force in well under a second, so
/// the iteration count is what does the work, not the algorithm.
///
/// This raises the cost of reading a PIN out of a stolen database. It does not
/// stop someone holding the unlocked device, and no local-only scheme can.
class PinHasher {
  const PinHasher({this.iterations = 60000});

  /// High enough to cost a deliberate attack, low enough that a shop counter
  /// signing in does not feel it. Measured in the low hundreds of ms on a
  /// desktop; on a low-end phone this is the slowest thing the app does, which
  /// is the correct trade for a four-digit secret.
  final int iterations;

  /// Per-member random salt. Never stored alongside a digest from another
  /// member, so identical PINs do not produce identical hashes.
  static String newSalt([Random? random]) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return base64UrlEncode(bytes);
  }

  String hash(String pin, String salt) {
    var digest = sha256.convert(utf8.encode('$salt:$pin')).bytes;
    for (var i = 1; i < iterations; i++) {
      digest = sha256.convert([...digest, ...utf8.encode(salt)]).bytes;
    }
    return base64UrlEncode(digest);
  }

  /// Constant-time comparison.
  ///
  /// `==` on strings short-circuits at the first differing byte, so an attacker
  /// timing repeated attempts learns the digest one character at a time. The
  /// whole comparison is a few hundred iterations either way; the difference
  /// is not free on any machine that can run this.
  bool verify(String pin, {required String? hash, required String? salt}) {
    if (hash == null || salt == null) return false;
    final candidate = this.hash(pin, salt);
    if (candidate.length != hash.length) return false;
    var diff = 0;
    for (var i = 0; i < candidate.length; i++) {
      diff |= candidate.codeUnitAt(i) ^ hash.codeUnitAt(i);
    }
    return diff == 0;
  }
}
