import 'package:atria/core/api/server_session.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The session is what decides whether this device may ask the server to do
/// anything, so the interesting cases are the ones where a stored token is
/// *not* usable: absent, or past its expiry.
///
/// Nothing in the app calls [ServerSession.save] yet — sign-in is not built —
/// so today the only path that matters in production is "no session". These
/// tests exist to pin the contract that sign-in will be written against, and to
/// keep the read half honest in the meantime.
void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late ServerSession session;

  setUp(() {
    db = AppDatabase.test(NativeDatabase.memory());
    settings = SettingsRepository(db);
    session = ServerSession(settings);
  });

  tearDown(() => db.close());

  test('an install that has never signed in has no session', () async {
    expect(await session.current(), isNull);
  });

  test('a saved session comes back with its token and account', () async {
    await session.save(
      email: 'owner@yourfirm.in',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
    );

    final current = await session.current();
    expect(current, isNotNull);
    expect(current!.accessToken, 'access-1');
    expect(current.email, 'owner@yourfirm.in');
    expect(current.label, 'owner@yourfirm.in');
  });

  test('a refresh token alone is not a session', () async {
    // The refresh token is the longer-lived half; treating it as usable would
    // mean sending it as a Bearer token, which the server would reject.
    await settings.set(SettingsRepository.kRefreshToken, 'refresh-1');
    expect(await session.current(), isNull);
  });

  test('an expired access token is not a session', () async {
    // The failure this prevents: a stale token reaching the server mid-action
    // and coming back as a 401 that looks like a broken feature.
    await session.save(
      email: 'owner@yourfirm.in',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      expiresAt: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
    );
    expect(await session.current(), isNull);
  });

  test('a token with no recorded expiry is not trusted', () async {
    await settings.set(SettingsRepository.kAccessToken, 'access-1');
    expect(await session.current(), isNull);
  });

  test('an account with no email still has something to show', () async {
    await session.save(
      email: '',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
    );
    expect((await session.current())!.label, 'your Apex Books account');
  });

  test('clear wipes the whole session, not just the access token', () async {
    await session.save(
      email: 'owner@yourfirm.in',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
    );
    await session.clear();

    expect(await session.current(), isNull);
    // A leftover refresh token would let the next sign-in path quietly reuse a
    // session somebody thought they had ended.
    expect(await settings.get(SettingsRepository.kRefreshToken), isNull);
    expect(await settings.get(SettingsRepository.kAccessTokenExpiresAt), isNull);
    expect(await settings.get(SettingsRepository.kUserEmail), isNull);
  });
}
