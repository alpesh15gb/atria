import 'api_config.dart';
import 'server_client.dart' show ServerRequestException;
import 'server_http.dart';

/// A token pair the server issued, with the expiry worked out locally.
class AuthTokens {
  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.email,
  });

  final String accessToken;
  final String refreshToken;

  /// The instant the access token stops being usable, in UTC. Derived from the
  /// server's `expiresIn` seconds rather than trusted as an absolute time: a
  /// device whose clock is a few minutes out would otherwise compute an expiry
  /// in the past and refuse a perfectly good session.
  final DateTime expiresAt;

  /// The signed-in address, or '' when the response did not carry one (the
  /// refresh endpoint does not).
  final String email;
}

/// Sign-up, sign-in, refresh and sign-out against the Apex Books API.
///
/// Deliberately a separate class from [ServerClient]: sign-in has no token to
/// present, and everything else does, so mixing them would mean an
/// `accessToken` parameter that is sometimes null and sometimes load-bearing.
///
/// The password is never stored — not in settings, not in memory past the
/// request. Only the token pair is, and only through `ServerSession`.
class AuthClient {
  AuthClient(this._config, {this.timeout = const Duration(seconds: 20)});

  final ApiConfig _config;

  /// Generous on purpose: a sign-up runs bcrypt in Postgres, and a phone on a
  /// slow connection is the normal case, not the exception.
  final Duration timeout;

  /// Seconds of slack taken off the server's `expiresIn` before the expiry is
  /// stored.
  ///
  /// A token that expires while the request it authorised is still in flight
  /// would come back as "signed out" on a call the server actually accepted.
  /// It is subtracted, never added, so it is clamped at use: a server that
  /// answers `expiresIn: 0` (or omits the field in a shape this version does
  /// not read) means *this token is already spent*, and storing
  /// `0 - 30` seconds as its expiry made `ServerSession.current()` return null
  /// immediately — so every single `accessToken()` call rotated the refresh
  /// token again, and with server-side rotation a few refreshes walked the
  /// token chain off its end and signed the device out by itself.
  static const int expiryLeewaySeconds = 30;

  /// Creates an account and returns a session for it.
  ///
  /// The device identity travels with every sign-up and sign-in, so the server
  /// can list this install on its own and revoke it without touching the
  /// account's other devices.
  Future<AuthTokens> signUp({
    required String email,
    required String password,
  }) async {
    final body = await _withDeviceIdentity({'email': email, 'password': password});
    final json = await ServerHttp.requestJson(
      uri: await _config.endpoint('/v1/auth/signup'),
      body: body,
      timeout: timeout,
      timeoutMessage:
          'Creating your account is taking longer than ${timeout.inSeconds} '
          'seconds. Check this device is online, then try again.',
    );
    return _tokensFrom(json, fallbackEmail: email);
  }

  /// Signs in and returns a session.
  ///
  /// A wrong password and an unknown address come back as the same message, by
  /// design: the server refuses to say which it was, and neither does this.
  Future<AuthTokens> signIn({
    required String email,
    required String password,
  }) async {
    final body = await _withDeviceIdentity({'email': email, 'password': password});
    final json = await ServerHttp.requestJson(
      uri: await _config.endpoint('/v1/auth/login'),
      body: body,
      timeout: timeout,
      timeoutMessage:
          'Signing in is taking longer than ${timeout.inSeconds} seconds. '
          'Check this device is online, then try again.',
    );
    return _tokensFrom(json, fallbackEmail: email);
  }

  /// Exchanges a refresh token for a new pair.
  ///
  /// The server rotates the refresh token on every use, so the old one is dead
  /// the moment this succeeds — which is why the caller must persist the whole
  /// result rather than just the access token.
  Future<AuthTokens> refresh({required String refreshToken}) async {
    final json = await ServerHttp.requestJson(
      uri: await _config.endpoint('/v1/auth/refresh'),
      body: {'refreshToken': refreshToken},
      timeout: timeout,
    );
    return _tokensFrom(json, fallbackEmail: '');
  }

  /// Revokes this device's refresh token on the server.
  ///
  /// Best-effort by design: signing out has to work on a device with no signal,
  /// so the caller clears the local session whether or not this succeeds. The
  /// token stays valid server-side until it expires or is revoked from another
  /// device — which is exactly what the server's device list exists for.
  Future<void> signOut({required String refreshToken}) async {
    await ServerHttp.requestJson(
      uri: await _config.endpoint('/v1/auth/logout'),
      body: {'refreshToken': refreshToken},
      timeout: timeout,
    );
  }

  /// The account and its firm memberships, as the server sees them.
  Future<ServerAccount> me({required String accessToken}) async {
    final json = await ServerHttp.requestJson(
      uri: await _config.endpoint('/v1/me'),
      method: 'GET',
      accessToken: accessToken,
      timeout: timeout,
    );
    final user = json['user'];
    final email = user is Map ? (user['email'] as String? ?? '') : '';
    final deviceId = json['deviceId'] as String? ?? '';
    final firms = <ServerFirmMembership>[];
    final rawFirms = json['firms'];
    if (rawFirms is List) {
      for (final entry in rawFirms) {
        if (entry is Map) {
          final firmId = entry['firmId'];
          if (firmId is String && firmId.isNotEmpty) {
            firms.add(ServerFirmMembership(
              firmId: firmId,
              name: entry['firmName'] as String? ?? '',
              role: entry['role'] as String? ?? 'member',
            ));
          }
        }
      }
    }
    return ServerAccount(email: email, deviceId: deviceId, firms: firms);
  }

  /// Registers a firm on the server so a later push has somewhere to land.
  ///
  /// Idempotent from the client's point of view: the server answers 409 when the
  /// id already exists, and that is the goal state, so it is reported as
  /// success rather than an error the operator cannot act on.
  Future<void> registerFirm({
    required String accessToken,
    required String firmId,
    required String name,
    String? gstin,
    String? memberName,
  }) async {
    try {
      await ServerHttp.requestJson(
        uri: await _config.endpoint('/v1/firms'),
        accessToken: accessToken,
        timeout: timeout,
        body: {
          'firmId': firmId,
          'name': name,
          if (gstin != null && gstin.trim().isNotEmpty) 'gstin': gstin.trim(),
          if (memberName != null && memberName.trim().isNotEmpty)
            'memberName': memberName.trim(),
        },
      );
    } on ServerRequestException catch (error) {
      if (error.statusCode == 409) return;
      rethrow;
    }
  }

  Future<Map<String, Object?>> _withDeviceIdentity(
    Map<String, Object?> body,
  ) async {
    return {
      ...body,
      'deviceId': await _config.deviceId(),
      'deviceName': await _config.deviceName(),
      'platform': ApiConfig.platformName,
    };
  }

  /// Reads a token response, refusing a success that is missing the tokens it
  /// is supposed to carry.
  ///
  /// A 200 with no `accessToken` would otherwise become a session with an empty
  /// token, and every later request would fail as "signed out" — a confusing
  /// way to learn the server is not the Apex Books API.
  AuthTokens _tokensFrom(
    Map<String, Object?> json, {
    required String fallbackEmail,
  }) {
    final accessToken = (json['accessToken'] as String? ?? '').trim();
    final refreshToken = (json['refreshToken'] as String? ?? '').trim();
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      throw const ServerRequestException(
        'Apex Books answered without a session token. Check the server address in '
        'Settings — it may not be an Apex Books server.',
      );
    }

    final expiresIn = json['expiresIn'];
    final seconds = expiresIn is num
        ? expiresIn.toInt()
        : int.tryParse('${expiresIn ?? ''}') ?? 3600;

    final user = json['user'];
    final email = user is Map
        ? (user['email'] as String? ?? fallbackEmail)
        : fallbackEmail;

    return AuthTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      // Leeway clamped at zero: a non-positive `expiresIn` becomes "expires now",
      // which `ServerSession.current()` reads as needing a renewal — the one
      // honest answer. Subtracting from it unconditionally would store an
      // expiry that is already in the past, which reads identically on this
      // device but rotates the refresh token on every call from then on.
      expiresAt: DateTime.now().toUtc().add(
            Duration(
              seconds: seconds > expiryLeewaySeconds
                  ? seconds - expiryLeewaySeconds
                  : 0,
            ),
          ),
      email: email,
    );
  }
}

/// The account behind a session, as `/v1/me` reports it.
class ServerAccount {
  const ServerAccount({
    required this.email,
    required this.deviceId,
    required this.firms,
  });

  final String email;
  final String deviceId;
  final List<ServerFirmMembership> firms;
}

class ServerFirmMembership {
  const ServerFirmMembership({
    required this.firmId,
    required this.name,
    required this.role,
  });

  final String firmId;
  final String name;
  final String role;
}
