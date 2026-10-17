import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/auth_client.dart';
import '../api/server_client.dart' show ServerRequestException;
import '../api/server_session.dart';

/// What the app knows about this device's Apex Books account.
class AuthState {
  const AuthState({
    required this.ready,
    this.email = '',
    this.expiresAt,
    this.refreshing = false,
  });

  /// False until the stored session has been read once. The UI shows a
  /// spinner rather than "Sign in", so a signed-in device never flashes the
  /// signed-out state on launch.
  final bool ready;

  /// The signed-in address, or '' when signed out.
  final String email;

  final DateTime? expiresAt;

  /// True while a token refresh is in flight, so the UI can say "Reconnecting…"
  /// instead of offering a Sign in button that would create a second session.
  final bool refreshing;

  bool get signedIn => email.trim().isNotEmpty;

  /// An address worth showing in a menu.
  String get label => signedIn ? email : 'your Apex Books account';

  AuthState copyWith({
    bool? ready,
    String? email,
    DateTime? expiresAt,
    bool? refreshing,
  }) =>
      AuthState(
        ready: ready ?? this.ready,
        email: email ?? this.email,
        expiresAt: expiresAt ?? this.expiresAt,
        refreshing: refreshing ?? this.refreshing,
      );
}

/// Which of the three answers to "can this device talk to Apex Books right now?"
/// came back.
///
/// They are not three flavours of one answer, and the app used to report two
/// of them as the third: a renewal that failed because the phone was on a train
/// returned the same null as a renewal the server had rejected, so the sync
/// engine stamped "Sign in to Apex Books to sync" and the business-removal sheet
/// disabled its server option with "Sign in to Apex Books on this device first".
/// Only [noSession] is actionable by the user; offering a sign-in prompt for
/// [temporarilyUnavailable] sends someone to a password screen they do not
/// need, on the one screen that then tells them the books are not syncing.
enum TokenRefreshOutcome {
  /// A usable access token is in hand — either the stored one was still live,
  /// or the pair was rotated successfully.
  ok,

  /// This device has no session: never signed in, or the server rejected the
  /// refresh token (401/403) and the stored one was cleared.
  noSession,

  /// A session exists and is intact, but Apex Books could not be reached this time
  /// (offline, DNS, timeout, server down). Nothing has been lost and nothing
  /// needs to be re-entered — the pending work simply has to wait.
  temporarilyUnavailable,
}

/// The answer to "give me an access token", told apart by cause.
///
/// Kept as one type rather than a bare `String?` so that a caller which has to
/// *choose what to say to the user* — the sync engine, the account card, the
/// server erase — can do so without re-deriving the policy, and so that
/// `null` never has to mean both "sign in" and "try again later".
class AccessTokenResult {
  const AccessTokenResult.ok(String this.accessToken)
      : outcome = TokenRefreshOutcome.ok;

  const AccessTokenResult.noSession()
      : accessToken = null,
        outcome = TokenRefreshOutcome.noSession;

  const AccessTokenResult.temporarilyUnavailable()
      : accessToken = null,
        outcome = TokenRefreshOutcome.temporarilyUnavailable;

  /// The token to send, or null when there is not one to send. Null alone
  /// still says nothing about *why* — read [outcome] for that.
  final String? accessToken;

  final TokenRefreshOutcome outcome;

  bool get ok => outcome == TokenRefreshOutcome.ok;

  /// True only when the account really is signed out. The single flag a UI
  /// should gate an "Sign in" affordance on.
  bool get needsSignIn => outcome == TokenRefreshOutcome.noSession;

  /// True when the session survived and the network did not. Wording should
  /// offer a retry or simply wait, never a password.
  bool get temporarilyUnavailable =>
      outcome == TokenRefreshOutcome.temporarilyUnavailable;
}

/// Owns this device's session: loading it, renewing it, and signing in or out.
///
/// Sits between [ServerSession] (which only knows how to read and write the
/// four keys) and the network, because *renewing a token is a network call that
/// can fail* and that policy has to live somewhere. The rule it enforces:
///
/// * a live access token is used as-is, with no round trip;
/// * an expired one is renewed once, silently, if there is a refresh token;
/// * a renewal the server rejects (401/403) clears the session locally, because
///   retrying a token the server has revoked can never succeed;
/// * a renewal that merely failed (offline, timeout) leaves the session in
///   place — being offline is not being signed out.
///
/// Refresh tokens rotate on every use, so a successful refresh must be
/// persisted immediately: the old token is dead the moment the server answers.
class AuthController extends StateNotifier<AuthState> {
  AuthController(this._session, this._client)
      : super(const AuthState(ready: false)) {
    _load();
  }

  final ServerSession _session;
  final AuthClient _client;

  /// The signed-in address, for callers that want the value without watching
  /// the whole state (the sync engine registers a firm under it).
  String get email => state.email;

  /// Serialises refreshes. Two callers (a sync push and a manual erase) hitting
  /// an expiry at the same moment must not both rotate the refresh token: the
  /// second request would present a token the first already replaced, and the
  /// device would be signed out by its own retry.
  Future<AccessTokenResult>? _refreshInFlight;

  Future<void> _load() async {
    try {
      final current = await _session.current();
      if (!mounted) return;
      if (current != null) {
        state = AuthState(
          ready: true,
          email: current.email,
          expiresAt: current.expiresAt,
        );
        return;
      }
      // A stored refresh token means the device *was* signed in and only the
      // access token expired. Renew it now so the app comes back up signed in
      // rather than asking for a password on every launch.
      final refresh = await _session.refreshToken();
      if (!mounted) return;
      if (refresh == null) {
        state = const AuthState(ready: true);
        return;
      }
      state = state.copyWith(ready: true, refreshing: true);
      // _renew sets the final state itself, in all three of its outcomes —
      // including the transient one, which is the only way `refreshing` ever
      // gets cleared on this path. _load runs exactly once, so leaving it set
      // would show "Renewing this device's session…" beside a perfectly good
      // account for the rest of the session.
      await _renew(refresh);
    } catch (_) {
      // A database that will not read is a boot problem the app already
      // reports elsewhere; this screen must still open, signed out.
      if (mounted) state = const AuthState(ready: true);
    }
  }

  /// Signs in with a password. Throws [ServerRequestException] with a message
  /// written for the person who typed it.
  Future<void> signIn({required String email, required String password}) async {
    final tokens = await _client.signIn(email: email, password: password);
    await _store(tokens);
  }

  /// Creates an account and signs in to it.
  Future<void> signUp({required String email, required String password}) async {
    final tokens = await _client.signUp(email: email, password: password);
    await _store(tokens);
  }

  /// Signs out: revokes the token server-side when it can, and always clears
  /// the local session.
  ///
  /// Returns a note for the UI when the revoke could not be delivered, because
  /// signing out on a train should still work — the token simply stays valid
  /// until it expires or is revoked from another device, and the person deserves
  /// to be told that rather than shown a failure that undid nothing.
  Future<String?> signOut() async {
    final refresh = await _session.refreshToken();
    String? note;
    if (refresh != null) {
      try {
        await _client.signOut(refreshToken: refresh);
      } on ServerRequestException catch (error) {
        note = error.statusCode == null
            ? 'Signed out on this device. Apex Books was unreachable, so the '
                'session stays listed until it expires.'
            : 'Signed out on this device. Apex Books said: ${error.message}';
      }
    }
    await _session.clear();
    if (mounted) state = const AuthState(ready: true);
    return note;
  }

  /// A usable access token, or null when this device cannot get one.
  ///
  /// Retained for callers that only need to know *whether* to make a request —
  /// a null here is a perfectly good reason to stop. Callers that have to tell
  /// the user what went wrong must use [resolveAccessToken] instead: for them
  /// null means "signed out" and "no signal" interchangeably, and those two
  /// need opposite wording.
  Future<String?> accessToken() async =>
      (await resolveAccessToken()).accessToken;

  /// A usable access token, and which of the three outcomes it was.
  ///
  /// Renews an expired token when it can. Callers that talk to the server (the
  /// sync push, erase-on-server) go through here rather than reading the
  /// settings row, so the renewal rule lives in exactly one place.
  ///
  /// Check [AccessTokenResult.needsSignIn] before telling anybody to sign in,
  /// and [AccessTokenResult.temporarilyUnavailable] before telling them to
  /// try again.
  Future<AccessTokenResult> resolveAccessToken() async {
    final current = await _session.current();
    if (current != null) return AccessTokenResult.ok(current.accessToken);

    final refresh = await _session.refreshToken();
    if (refresh == null) return const AccessTokenResult.noSession();

    final pending = _refreshInFlight ??= _renew(refresh);
    try {
      return await pending;
    } finally {
      _refreshInFlight = null;
    }
  }

  /// Rotates the token pair and reports which of the three outcomes it was.
  ///
  /// Returns rather than throws for every failure: the three outcomes *are*
  /// the policy, and a caller forced to catch an exception to learn "the
  /// network is down" is a caller that will eventually forget to.
  Future<AccessTokenResult> _renew(String refreshToken) async {
    try {
      final tokens = await _client.refresh(refreshToken: refreshToken);
      await _session.updateTokens(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresAt,
      );
      final email = tokens.email.isEmpty
          ? (await _session.current())?.email ?? ''
          : tokens.email;
      if (mounted) {
        state = AuthState(
          ready: true,
          email: email,
          expiresAt: tokens.expiresAt,
        );
      }
      return AccessTokenResult.ok(tokens.accessToken);
    } on ServerRequestException catch (error) {
      if (error.signedOut) {
        // The server will never accept this refresh token again.
        await _session.clear();
        if (mounted) state = const AuthState(ready: true);
        return const AccessTokenResult.noSession();
      }
      // Offline, or the server is down. Keep the session: the user is still
      // signed in, they just cannot reach Apex Books right now.
      //
      // The state is settled here rather than by the caller because this is
      // the only path that can strand `refreshing` on: _load sets it true and
      // runs once, and returning a result to a caller that has already moved
      // on (or to nobody, on the launch path) leaves the account card reading
      // "Renewing this device's session…" for ever. The stored address is
      // restored so the same card does not read "Not signed in" beside it.
      final email = await _session.signedInEmail();
      if (mounted) {
        state = state.copyWith(ready: true, refreshing: false, email: email);
      }
      return const AccessTokenResult.temporarilyUnavailable();
    }
  }

  /// Registers a firm on the server, so a later change push has somewhere to
  Future<ServerAccount> cloudAccount(String accessToken) =>
      _client.me(accessToken: accessToken);

  /// Registers a firm on the server, so a later change push has somewhere to
  /// land. Idempotent: the server answers 409 for a firm it already has, and
  /// [AuthClient] reports that as success.
  ///
  /// Lives here rather than on the sync engine so the engine holds one
  /// collaborator for everything account-scoped, not two.
  Future<void> registerFirmForSync({
    required String accessToken,
    required String firmId,
    required String name,
    String? gstin,
    String? memberName,
  }) =>
      _client.registerFirm(
        accessToken: accessToken,
        firmId: firmId,
        name: name,
        gstin: gstin,
        memberName: memberName,
      );

  /// Re-reads the stored session — used after a sign-in that happened outside
  /// this controller (there is none today, but the app's own tests do it).
  Future<void> reload() => _load();

  Future<void> _store(AuthTokens tokens) async {
    await _session.save(
      email: tokens.email,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAt: tokens.expiresAt,
    );
    if (mounted) {
      state = AuthState(
        ready: true,
        email: tokens.email,
        expiresAt: tokens.expiresAt,
      );
    }
  }
}
