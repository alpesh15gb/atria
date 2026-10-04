import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../database/repositories/members_repository.dart';
import '../database/repositories/repository_extensions.dart';
import '../domain/member_role.dart';
import 'providers.dart';

/// The settings key that turns local users on for a firm.
const String kLocalUsersEnabledKey = 'local_users_enabled';

/// The on/off switch itself, so the setting has exactly one writer.
///
/// An extension rather than a repository method because it is a one-row
/// settings write, not a business operation — [SettingsRepository.set] is the
/// general door and this is the labelled one.
extension LocalUsersToggle on AppDatabase {
  Future<void> setLocalUsersEnabled(String firmId, bool enabled) {
    return settingsSet(
      kLocalUsersEnabledKey,
      enabled ? '1' : '0',
      firmId: firmId,
    );
  }
}

/// Whether the firm has opted into the PIN gate at all.
///
/// **The whole feature hangs off this being false.** With it off there is no
/// gate widget, no picker and — the part that matters — `AppDatabase.session`
/// stays [MemberSession.off], which grants every permission. So "off" is not a
/// different configuration of the gate; it is the absence of one, and nothing
/// in the write path can tell the difference.
final localUsersEnabledProvider = FutureProvider<bool>((ref) async {
  final firmId = ref.watch(activeFirmIdProvider);
  if (firmId == null) return false;
  final value = await ref
      .read(settingsRepositoryProvider)
      .get(kLocalUsersEnabledKey, firmId: firmId);
  return value == '1' || value == 'true';
});

final membersRepositoryProvider = Provider<MembersRepository?>((ref) {
  final firmId = ref.watch(activeFirmIdProvider);
  final db = ref.watch(appDatabaseProvider);
  if (firmId == null) return null;
  return db.membersRepositoryFor(firmId);
});

/// Everyone on the roster, including deactivated ones.
final membersProvider = StreamProvider<List<FirmMemberEntity>>((ref) {
  final repo = ref.watch(membersRepositoryProvider);
  if (repo == null) return Stream.value(const []);
  return repo.watchAll();
});

/// Who is at the counter, and what they may do.
///
/// This is the single mutable holder of [MemberSession] in the app, and the
/// gate writes to it through here rather than touching `AppDatabase.session`
/// directly — that way "turn the feature off" and "sign out" are the same
/// observable transition, and the overlay cannot be left showing over an app
/// that has stopped checking permissions.
class MemberSessionController extends StateNotifier<MemberSession> {
  MemberSessionController(this._db) : super(MemberSession.off);

  final AppDatabase _db;

  /// The one write that makes the whole feature real.
  ///
  /// Sets the in-memory session, which is what every repository guard reads.
  /// Deliberately not persisted: a PIN gate that re-locks on relaunch without
  /// asking would be a surprise, and this is a shop counter, not a bank.
  void signIn(MemberSession session) {
    _db.session = session;
    state = session;
  }

  /// Back to "nobody is signed in", without turning the feature off.
  void signOut() {
    _db.session = MemberSession.off;
    state = MemberSession.off;
  }

  /// Turns local users off entirely — no gate, everyone allowed again.
  ///
  /// Clears the session rather than leaving it in place: a firm that has just
  /// decided not to use PINs must not still be filtering writes by the role of
  /// whoever happened to be signed in.
  void disable() {
    _db.session = MemberSession.off;
    state = MemberSession.off;
  }
}

final memberSessionProvider =
    StateNotifierProvider<MemberSessionController, MemberSession>((ref) {
      return MemberSessionController(ref.watch(appDatabaseProvider));
    });

/// The signed-in session, or off when nobody is or the feature is off.
final effectiveSessionProvider = Provider<MemberSession>((ref) {
  final enabled = ref.watch(localUsersEnabledProvider);
  final session = ref.watch(memberSessionProvider);
  return enabled.valueOrNull == true ? session : MemberSession.off;
});

/// Whether the gate should be on screen right now.
///
/// Four conditions, and the middle two are what stop this feature from locking
/// a shop out of its own books — the failure nobody would report and nobody
/// could work around:
///
///  * the firm opted in;
///  * somebody is on the roster who **can actually get in** — active *and*
///    holding a PIN, because a member with no PIN can be picked but will fail
///    every entry, which is a dead end rather than a gate;
///  * nobody is signed in yet.
///
/// So a firm that flips the switch before adding anyone, or whose only member
/// has not been given a PIN yet, keeps a working app.
final pinGateVisibleProvider = Provider<bool>((ref) {
  if (ref.watch(localUsersEnabledProvider).valueOrNull != true) return false;
  final members = ref.watch(membersProvider).valueOrNull;
  if (members == null || !members.any((m) => m.isActive && m.pinHash != null)) {
    return false;
  }
  return !ref.watch(memberSessionProvider).isSignedIn;
});

/// Convenience for screens: `ref.watch(sessionCanProvider(Permission.purge))`.
///
/// Returns false only when the session is genuinely on and the role lacks the
/// permission — the same two conditions [AppDatabase.assertPermission] uses,
/// so a screen and its repository can never disagree about whether an action is
/// allowed.
final sessionCanProvider = Provider.family<bool, Permission>((ref, permission) {
  return ref.watch(effectiveSessionProvider).allows(permission);
});
