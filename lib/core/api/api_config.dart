import 'dart:io';

import '../database/repositories/settings_repository.dart';
import '../utils/id_utils.dart';

/// How this install reaches the Apex Books server, and how it identifies itself.
///
/// The app is offline-first, so nothing here is required for it to work: no
/// request is made until a feature asks for one. This class answers only two
/// questions — *which* server, and *who* is asking.
class ApiConfig {
  ApiConfig(this._settings);

  final SettingsRepository _settings;

  /// The server in this repo's `server/` directory: Postgres plus the Dart API,
  /// fronted by host nginx on `api.apexbooks.in` with Let's Encrypt TLS.
  static const String productionBaseUrl = 'https://api.apexbooks.in';

  /// Build-time override, for development and CI:
  ///
  ///     flutter run --dart-define=ATRIA_API_BASE_URL=http://localhost:8090
  ///
  /// A saved setting wins over this, and this wins over [productionBaseUrl].
  static const String _buildTimeBaseUrl =
      String.fromEnvironment('ATRIA_API_BASE_URL');

  /// The server address, resolved fresh on every call.
  ///
  /// Deliberately not cached: the Settings screen writes
  /// [SettingsRepository.kApiBaseUrl] at runtime, and a cached field would keep
  /// sending requests to the previous server until the app restarted — which is
  /// exactly the half-configured state this class exists to prevent.
  ///
  /// Throws [FormatException] if the stored address is unusable. It does *not*
  /// fall back to production: silently redirecting a request to a different
  /// server than the one the user typed is worse than failing.
  Future<String> baseUrl() async {
    final configured =
        (await _settings.get(SettingsRepository.kApiBaseUrl))?.trim() ?? '';
    if (configured.isNotEmpty) return normaliseBaseUrl(configured);

    final buildTime = _buildTimeBaseUrl.trim();
    if (buildTime.isNotEmpty) return normaliseBaseUrl(buildTime);

    return productionBaseUrl;
  }

  /// A complete URL for [path], e.g. `/v1/auth/login`.
  Future<Uri> endpoint(String path) async {
    final base = await baseUrl();
    return Uri.parse(path.startsWith('/') ? '$base$path' : '$base/$path');
  }

  /// Normalises a user-entered server address, or throws [FormatException]
  /// carrying a message worth showing to the person who typed it.
  ///
  /// Normalisation is not cosmetic — `https://api.apexbooks.in/` and
  /// `.../v1` both look plausible, and would produce `/v1//auth/login` and
  /// `/v1/v1/auth/login`. Trailing slashes are stripped; a path is refused
  /// outright, because every endpoint appends its own.
  static String normaliseBaseUrl(String raw) {
    // A trailing slash — or several, from a copy-paste — is harmless here, so
    // tolerate it rather than making the user notice and retype.
    final trimmed = raw.trim().replaceFirst(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) {
      throw const FormatException('Enter your server address.');
    }

    // A bare `api.apexbooks.in` is what most people type. Assume https rather
    // than rejecting it, since http could never be right for a remote host.
    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) {
      throw FormatException('"$trimmed" is not a server address.');
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw FormatException('Use https:// — not "${uri.scheme}://".');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException(
          'Remove the credentials from the address — sign-in handles that.');
    }
    if (uri.path.isNotEmpty && uri.path != '/') {
      throw const FormatException(
          'Use the server address only, with no path after it.');
    }

    final host = uri.host.toLowerCase();

    // `Uri.parse` is lenient enough to turn "not a url" into the host
    // `not%20a%20url`, which would then fail later as a DNS error the person
    // cannot act on. A host is letters, digits, dots and hyphens — plus colons
    // for an IPv6 literal.
    final isIpv6 = host.contains(':');
    final looksLikeHost = isIpv6
        ? RegExp(r'^[0-9a-f:]+$').hasMatch(host)
        : RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?'
                r'(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$')
            .hasMatch(host);
    if (!looksLikeHost) {
      throw FormatException('"$trimmed" is not a server address.');
    }

    // Plaintext to a remote host would put passwords on the wire in the clear.
    // Loopback is the one place http is legitimate, for local development.
    final isLoopback =
        host == 'localhost' || host == '127.0.0.1' || host == '::1';
    if (uri.scheme == 'http' && !isLoopback) {
      throw FormatException(
          '$host is not this machine, so the address must be https://.');
    }

    // Rebuild rather than string-trim, so the default port drops
    // (`https://host:443` prints as `https://host`) and an IPv6 host keeps its
    // brackets. Lowercasing the host matches how DNS resolves it anyway.
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }

  /// The shape a `TextFormField.validator` wants: null when fine, otherwise the
  /// reason. Shares [normaliseBaseUrl] so the field and the client can never
  /// disagree about what is acceptable.
  static String? validateBaseUrl(String? raw) {
    try {
      normaliseBaseUrl(raw ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  /// A stable id for this install, minted on first use and then persisted.
  ///
  /// Not derived from hardware or hostname on purpose: a cloned VM image or a
  /// renamed machine must not look like a second device, and a device the
  /// server has already issued refresh tokens to must stay recognisable so one
  /// lost install can be revoked without signing the others out.
  Future<String> deviceId() async {
    // Single-flight. Two callers racing on first launch must not each mint an
    // id with one of the two writes losing — the loser would then send a
    // deviceId the server has never seen.
    final pending = _deviceId ??= _loadOrMintDeviceId();
    try {
      return await pending;
    } catch (_) {
      _deviceId = null; // never cache a failure; let the next caller retry
      rethrow;
    }
  }

  Future<String>? _deviceId;

  Future<String> _loadOrMintDeviceId() async {
    final existing = await _settings.get(SettingsRepository.kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;

    // UUID v7, matching every other id the app mints: sortable by creation
    // time, so server-side logs read in the order things actually happened.
    final minted = IdUtils.newId();
    await _settings.set(SettingsRepository.kDeviceId, minted);
    return minted;
  }

  /// A human label for the device list, captured once.
  ///
  /// Captured rather than recomputed so that renaming the machine does not
  /// orphan the entry the user already recognises as theirs.
  Future<String> deviceName() async {
    final existing = await _settings.get(SettingsRepository.kDeviceName);
    if (existing != null && existing.isNotEmpty) return existing;

    final name = _hostname() ?? _fallbackDeviceName();
    await _settings.set(SettingsRepository.kDeviceName, name);
    return name;
  }

  static String? _hostname() {
    try {
      final name = Platform.localHostname.trim();
      return name.isEmpty ? null : name;
    } catch (_) {
      // localHostname throws on platforms that cannot resolve one.
      return null;
    }
  }

  static String _fallbackDeviceName() => switch (Platform.operatingSystem) {
        'windows' => 'Windows PC',
        'android' => 'Android device',
        'ios' => 'iPhone or iPad',
        'macos' => 'Mac',
        'linux' => 'Linux desktop',
        _ => 'This device',
      };

  /// The `platform` value the API records against a device.
  static String get platformName => Platform.operatingSystem;
}
