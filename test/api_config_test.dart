import 'package:atria/core/api/api_config.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The server address is typed by hand in Settings, and it decides where
/// sign-in requests — and therefore passwords — are sent. So the awkward
/// inputs matter more than the happy one: a trailing slash, a path, a missing
/// scheme, or plaintext http to a remote host.
///
/// The device id matters for a different reason: the server binds refresh
/// tokens to it, so minting a *second* one on a machine signs that machine out
/// of everything it was signed in to.
void main() {
  group('normaliseBaseUrl', () {
    test('assumes https for a bare host', () {
      expect(
        ApiConfig.normaliseBaseUrl('api.apexbooks.in'),
        'https://api.apexbooks.in',
      );
    });

    test('strips a trailing slash, which would otherwise double up', () {
      // Without this, "/v1/auth/login" appends to ".../" and the server sees a
      // path it does not route.
      expect(
        ApiConfig.normaliseBaseUrl('https://api.apexbooks.in/'),
        'https://api.apexbooks.in',
      );
      expect(
        ApiConfig.normaliseBaseUrl('  https://api.apexbooks.in//  '),
        'https://api.apexbooks.in',
      );
    });

    test('keeps a non-default port', () {
      expect(
        ApiConfig.normaliseBaseUrl('http://127.0.0.1:8090'),
        'http://127.0.0.1:8090',
      );
    });

    test('refuses a path, since every endpoint appends its own', () {
      expect(
        () => ApiConfig.normaliseBaseUrl('https://api.apexbooks.in/v1'),
        throwsFormatException,
      );
    });

    test('refuses plaintext http to a remote host', () {
      // http here would put the password on the wire in the clear.
      expect(
        () => ApiConfig.normaliseBaseUrl('http://api.apexbooks.in'),
        throwsFormatException,
      );
    });

    test('allows http on loopback, where it is the normal way to work', () {
      expect(
        ApiConfig.normaliseBaseUrl('http://localhost:8090'),
        'http://localhost:8090',
      );
    });

    test('refuses anything that is not an address', () {
      for (final bad in ['', '   ', 'not a url', 'ftp://api.apexbooks.in']) {
        expect(
          () => ApiConfig.normaliseBaseUrl(bad),
          throwsFormatException,
          reason: '"$bad" must be rejected',
        );
      }
    });

    test('drops credentials embedded in the address', () {
      expect(
        () => ApiConfig.normaliseBaseUrl('https://user:pw@api.apexbooks.in'),
        throwsFormatException,
      );
    });

    test('validateBaseUrl returns the reason instead of throwing', () {
      expect(ApiConfig.validateBaseUrl('api.apexbooks.in'), isNull);
      expect(ApiConfig.validateBaseUrl('https://api.apexbooks.in/v1'),
          isNotEmpty);
      expect(ApiConfig.validateBaseUrl(null), isNotEmpty);
    });
  });

  group('baseUrl', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late ApiConfig config;

    // Same compile-time define the app is built with, so the expectation holds
    // whether or not this test run passes --dart-define.
    const buildTime = String.fromEnvironment('ATRIA_API_BASE_URL');

    setUp(() {
      db = AppDatabase.test(NativeDatabase.memory());
      settings = SettingsRepository(db);
      config = ApiConfig(settings);
    });

    tearDown(() => db.close());

    test('uses the deployed server when nothing overrides it', () async {
      final expected = buildTime.isEmpty
          ? ApiConfig.productionBaseUrl
          : ApiConfig.normaliseBaseUrl(buildTime);
      expect(await config.baseUrl(), expected);
      expect(await config.baseUrl(), startsWith('https://'));
    });

    test('a saved setting wins', () async {
      await settings.set(
          SettingsRepository.kApiBaseUrl, 'https://staging.apexbooks.in/');
      expect(await config.baseUrl(), 'https://staging.apexbooks.in');
    });

    test('a truncated saved address throws instead of quietly using the real '
        'server', () async {
      // The dangerous failure mode: the user meant staging, and a silent
      // fallback sends their sign-in to production.
      await settings.set(
          SettingsRepository.kApiBaseUrl, 'https://api.apexbooks.in/v1');
      expect(() => config.baseUrl(), throwsFormatException);
    });

    test('endpoint joins cleanly against a slash-terminated address', () async {
      await settings.set(
          SettingsRepository.kApiBaseUrl, 'https://api.apexbooks.in/');
      expect(
        (await config.endpoint('/v1/auth/login')).toString(),
        'https://api.apexbooks.in/v1/auth/login',
      );
      expect(
        (await config.endpoint('v1/me')).toString(),
        'https://api.apexbooks.in/v1/me',
      );
    });
  });

  group('device identity', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late ApiConfig config;

    setUp(() {
      db = AppDatabase.test(NativeDatabase.memory());
      settings = SettingsRepository(db);
      config = ApiConfig(settings);
    });

    tearDown(() => db.close());

    test('the id is a UUID v7, matching every other id the app mints', () async {
      expect(
        await config.deviceId(),
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });

    test('the id is minted once and then found, not re-minted', () async {
      final first = await config.deviceId();
      expect(await config.deviceId(), first);

      // A fresh ApiConfig over the same database — i.e. the next app launch.
      final nextLaunch = ApiConfig(SettingsRepository(db));
      expect(await nextLaunch.deviceId(), first);
    });

    test('concurrent first callers share one id', () async {
      // Two panels asking at once on first launch must not mint two ids, with
      // one write losing and the loser using a deviceId the server never saw.
      final ids = await Future.wait([
        config.deviceId(),
        config.deviceId(),
        config.deviceId(),
      ]);
      expect(ids.toSet(), hasLength(1));
    });

    test('the device name is captured once', () async {
      final name = await config.deviceName();
      expect(name, isNotEmpty);

      final nextLaunch = ApiConfig(SettingsRepository(db));
      expect(await nextLaunch.deviceName(), name);
    });

    test('platform is reported for the device the server will list', () {
      expect(ApiConfig.platformName, isNotEmpty);
    });
  });
}
