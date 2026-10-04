import 'dart:convert';
import 'dart:io';

import 'package:atria/core/api/api_config.dart';
import 'package:atria/core/api/auth_client.dart';
import 'package:atria/core/api/server_session.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:atria/core/state/auth_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The session policy is the part of sign-in that is easy to get subtly wrong:
/// an expired access token must not read as "signed out", a rejected refresh
/// must, and being offline must be neither. Each of those is a different
/// branch, so each gets its own test against a real socket.
void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late AuthClient client;
  late ServerSession session;
  late HttpServer server;
  final paths = <String>[];

  late int status;
  late String body;

  setUp(() async {
    paths.clear();
    status = 200;
    body = jsonEncode({
      'accessToken': 'access-2',
      'refreshToken': 'refresh-2',
      'expiresIn': 900,
      'user': {'id': 'user-1', 'email': 'owner@apexbooks.in'},
    });

    db = AppDatabase.test(NativeDatabase.memory());
    settings = SettingsRepository(db);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      paths.add(request.uri.path);
      await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(body);
      await request.response.close();
    });
    await settings.set(
      SettingsRepository.kApiBaseUrl,
      'http://127.0.0.1:${server.port}',
    );

    final config = ApiConfig(settings);
    client = AuthClient(config, timeout: const Duration(seconds: 5));
    session = ServerSession(settings);
  });

  tearDown(() async {
    try {
      await server.close(force: true);
    } on Object {
      // already closed by a test
    }
    await db.close();
  });

  Future<AuthController> controller() async {
    final controller = AuthController(session, client);
    // Poll rather than await one future: the controller reports `ready` as soon
    // as it has read the stored keys and `refreshing` only afterwards, so both
    // have to settle before a test can assert on the outcome.
    for (var i = 0; i < 200; i++) {
      if (controller.state.ready && !controller.state.refreshing) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return controller;
  }

  test('a device with no stored session comes up signed out', () async {
    final auth = await controller();
    expect(auth.state.ready, true);
    expect(auth.state.signedIn, false);
    expect(paths, isEmpty);
    expect(await auth.accessToken(), null);
  });

  test('a live access token is used without any network call', () async {
    await session.save(
      email: 'owner@apexbooks.in',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );

    final auth = await controller();
    expect(auth.state.signedIn, true);
    expect(auth.state.email, 'owner@apexbooks.in');
    expect(await auth.accessToken(), 'access-1');
    expect(paths, isEmpty);
  });

  test('an expired access token is renewed silently on launch', () async {
    await session.save(
      email: 'owner@apexbooks.in',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
    );

    final auth = await controller();
    expect(paths, ['/v1/auth/refresh']);
    expect(auth.state.signedIn, true);
    expect(auth.state.email, 'owner@apexbooks.in');
    expect(await auth.accessToken(), 'access-2');
    // The rotated pair is persisted, because the presented token is dead.
    expect(await session.refreshToken(), 'refresh-2');
  });

  test('a refresh the server rejects signs the device out', () async {
    status = 401;
    body = jsonEncode({
      'error': {'code': 'unauthorized', 'message': 'Refresh token is not valid.'},
    });
    await session.save(
      email: 'owner@apexbooks.in',
      accessToken: 'access-1',
      refreshToken: 'revoked',
      expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
    );

    final auth = await controller();
    expect(auth.state.signedIn, false);
    expect(await session.refreshToken(), null);
    expect(await session.current(), null);
  });

  test('being offline does not sign the device out', () async {
    await session.save(
      email: 'owner@apexbooks.in',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
    );
    await server.close(force: true);

    final auth = await controller();
    // No token to hand out, but the session itself survives: a later launch
    // with signal renews and the user is not asked for a password.
    expect(await auth.accessToken(), null);
    expect(await session.refreshToken(), 'refresh-1');
  });

  test('signing out clears the stored session even when offline', () async {
    await session.save(
      email: 'owner@apexbooks.in',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final auth = await controller();
    await server.close(force: true);

    final note = await auth.signOut();
    expect(auth.state.signedIn, false);
    expect(await session.current(), null);
    expect(await session.refreshToken(), null);
    // And the person is told the session outlived the sign-out server-side.
    expect(note, isNotNull);
    expect(note, contains('unreachable'));
  });

  test('signing out revokes the token when the server is reachable', () async {
    final auth = await controller();
    await auth.signIn(email: 'owner@apexbooks.in', password: 'longenough');
    expect(auth.state.signedIn, true);
    body = jsonEncode({'revoked': true});

    final note = await auth.signOut();
    expect(note, null);
    expect(paths, ['/v1/auth/login', '/v1/auth/logout']);
  });
}
