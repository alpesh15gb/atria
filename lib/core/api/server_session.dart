import '../database/repositories/settings_repository.dart';

/// A signed-in Apex Books account, as far as this device is concerned.
class SignedIn {
  const SignedIn({
    required this.email,
    required this.accessToken,
    required this.expiresAt,
  });

  final String email;
  final String accessToken;
  final DateTime expiresAt;

  /// An address worth showing in a menu, or 'your Apex Books account' when sign-in
  /// did not record one.
  String get label => email.trim().isEmpty ? 'your Apex Books account' : email;
}

/// The Apex Books account this install is signed in to, and the token requests carry.
///
/// Sign-in itself is not built yet, so nothing in the app calls [save] and
/// [current] returns null on every install today. That is the point of the
/// class rather than a stub in the UI: everything that needs to know whether
/// this device can talk to the server asks *here*, so when sign-in lands the
/// only thing that changes is who writes these four keys.
///
/// There is deliberately no refresh logic. Refreshing is a network call that
/// can fail, and pretending an expired token is usable would turn "sign in
/// again" into a confusing 401 from the middle of an unrelated request.
class ServerSession {
  ServerSession(this._settings);

  final SettingsRepository _settings;

  /// The live session, or null when this install is not signed in.
  Future<SignedIn?> current() async {
    final token = (await _settings.get(SettingsRepository.kAccessToken))?.trim();
    if (token == null || token.isEmpty) return null;

    final expiresAt = DateTime.tryParse(
      (await _settings.get(SettingsRepository.kAccessTokenExpiresAt)) ?? '',
    )?.toUtc();

    // Expiry is checked here rather than left to the server. An expired access
    // token would come back as a 401 from the *middle* of an action the user
    // asked for, which reads as "this feature is broken" instead of "sign in
    // again".
    if (expiresAt == null || !expiresAt.isAfter(DateTime.now().toUtc())) {
      return null;
    }

    return SignedIn(
      email: (await _settings.get(SettingsRepository.kUserEmail)) ?? '',
      accessToken: token,
      expiresAt: expiresAt,
    );
  }

  /// The refresh token, for the one caller that legitimately needs it: the
  /// token refresh in `AuthController`. Nothing else may read it.
  Future<String?> refreshToken() async {
    final token = (await _settings.get(SettingsRepository.kRefreshToken))?.trim();
    return (token == null || token.isEmpty) ? null : token;
  }

  /// The address recorded for the session, whether or not the access token is
  /// still live.
  ///
  /// [current] cannot answer this once the access token has expired, but a
  /// device whose renewal simply failed offline is still the same person: the
  /// refresh token is intact and will work on the next launch with signal.
  /// Reporting that as "Not signed in" would ask for a password the person
  /// cannot usefully enter, so the account card reads this instead.
  Future<String> signedInEmail() async {
    return (await _settings.get(SettingsRepository.kUserEmail)) ?? '';
  }

  /// Replaces the token pair after a refresh, keeping the recorded address.
  ///
  /// Separate from [save] because a refresh response carries no `user` object —
  /// calling [save] with an empty email would erase the address that makes the
  /// session recognisable in Settings.
  Future<void> updateTokens({
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAt,
  }) async {
    await _settings.set(SettingsRepository.kAccessToken, accessToken);
    await _settings.set(SettingsRepository.kRefreshToken, refreshToken);
    await _settings.set(
      SettingsRepository.kAccessTokenExpiresAt,
      expiresAt.toUtc().toIso8601String(),
    );
  }

  /// Records a session. The access token's expiry is stored alongside it so
  /// [current] can tell a live session from a stale one without a round trip.
  Future<void> save({
    required String email,
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAt,
  }) async {
    await _settings.set(SettingsRepository.kUserEmail, email);
    await _settings.set(SettingsRepository.kAccessToken, accessToken);
    await _settings.set(SettingsRepository.kRefreshToken, refreshToken);
    await _settings.set(
      SettingsRepository.kAccessTokenExpiresAt,
      expiresAt.toUtc().toIso8601String(),
    );
  }

  /// Forgets the session. Deliberately local: revoking the refresh token is a
  /// network call, and signing out has to work on a device with no signal.
  /// The token stays valid server-side until it is revoked or expires, which
  /// is why the server keeps a device list.
  Future<void> clear() async {
    await _settings.remove(SettingsRepository.kAccessToken);
    await _settings.remove(SettingsRepository.kRefreshToken);
    await _settings.remove(SettingsRepository.kAccessTokenExpiresAt);
    await _settings.remove(SettingsRepository.kUserEmail);
  }
}
