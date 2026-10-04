import 'dart:convert';
import 'dart:io';

import 'package:atria/core/api/api_config.dart';
import 'package:atria/core/api/auth_client.dart';
import 'package:atria/core/api/server_client.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sign-in is the gate in front of everything account-scoped, so the wire
/// format it depends on is worth pinning down request by request: which path,
/// what the body carries, and — most importantly — what a device is told when
/// the server refuses.
///
/// A real [HttpServer] on loopback rather than a mock, for the same reason
/// `server_client_test.dart` uses one: the interesting behaviour is a status
/// code and a JSON body crossing a socket.
void main() {
  late AppDatabase db;
  late HttpServer server;
  late AuthClient client;
  final requests = <HttpRequest>[];
  final bodies = <String>[];

  late int status;
  late String body;

  setUp(() async {
    requests.clear();
    bodies.clear();
    status = 200;
    body = jsonEncode({
      'accessToken': 'access-1',
      'refreshToken': 'refresh-1',
      'tokenType': 'Bearer',
      'expiresIn': 900,
      'user': {'id': 'user-1', 'email': 'owner@apexbooks.in'},
    });

    db = AppDatabase.test(NativeDatabase.memory());
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request);
      final raw = await utf8.decoder.bind(request).join();
      bodies.add(raw);
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(body);
      await request.response.close();
    });

    final settings = SettingsRepository(db);
    await settings.set(
      SettingsRepository.kApiBaseUrl,
      'http://127.0.0.1:${server.port}',
    );
    client = AuthClient(ApiConfig(settings), timeout: const Duration(seconds: 5));
  });

  tearDown(() async {
    // One test closes the server itself, to prove the offline path; closing a
    // closed server is not an error, but it is also not worth relying on.
    try {
      await server.close(force: true);
    } on Object {
      // already closed
    }
    await db.close();
  });

  test('sign in posts to /v1/auth/login with the device identity', () async {
    await client.signIn(email: 'owner@apexbooks.in', password: 'longenough');

    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.uri.path, '/v1/auth/login');

    final sent = jsonDecode(bodies.single) as Map<String, Object?>;
    expect(sent['email'], 'owner@apexbooks.in');
    expect(sent['password'], 'longenough');
    // The device identity is what makes a session revocable per install.
    expect((sent['deviceId'] as String).isNotEmpty, true);
    expect((sent['deviceName'] as String).isNotEmpty, true);
    expect((sent['platform'] as String).isNotEmpty, true);

    // And the device id is the one the settings row now holds, so a later
    // sign-in from this install presents the same identity.
    final stored = SettingsRepository(db);
    expect(await stored.get(SettingsRepository.kDeviceId), sent['deviceId']);
  });

  test('sign up posts to /v1/auth/signup', () async {
    await client.signUp(email: 'new@apexbooks.in', password: 'longenough');
    expect(requests.single.uri.path, '/v1/auth/signup');
  });

  test('a successful sign-in yields tokens with the account address', () async {
    final tokens = await client.signIn(
      email: 'owner@apexbooks.in',
      password: 'longenough',
    );
    expect(tokens.accessToken, 'access-1');
    expect(tokens.refreshToken, 'refresh-1');
    expect(tokens.email, 'owner@apexbooks.in');
    // 900s minus the 30s of slack, so a token is never used right as it
    // expires mid-request.
    final slack = tokens.expiresAt.difference(DateTime.now().toUtc()).inSeconds;
    expect(slack, inInclusiveRange(840, 870));
  });

  test('refresh carries the presented token and returns the new pair', () async {
    body = jsonEncode({
      'accessToken': 'access-2',
      'refreshToken': 'refresh-2',
      'tokenType': 'Bearer',
      'expiresIn': 900,
    });

    final tokens = await client.refresh(refreshToken: 'refresh-1');
    expect(requests.single.uri.path, '/v1/auth/refresh');
    expect(
      (jsonDecode(bodies.single) as Map)['refreshToken'],
      'refresh-1',
    );
    expect(tokens.accessToken, 'access-2');
    expect(tokens.refreshToken, 'refresh-2');
    // The refresh endpoint carries no user object; the caller keeps the address
    // it already had rather than blanking it.
    expect(tokens.email, '');
  });

  test('a refused sign-in surfaces the server message and stays signed out',
      () async {
    status = 401;
    body = jsonEncode({
      'error': {
        'code': 'unauthorized',
        'message': 'Email or password is incorrect.',
      },
    });

    await expectLater(
      client.signIn(email: 'owner@apexbooks.in', password: 'wrong'),
      throwsA(
        isA<ServerRequestException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message', 'Email or password is incorrect.'),
      ),
    );
  });

  test('a 200 without tokens is refused rather than becoming an empty session',
      () async {
    // What a non-Apex Books server answering 200 looks like.
    body = jsonEncode({'ok': true});

    await expectLater(
      client.signIn(email: 'owner@apexbooks.in', password: 'longenough'),
      throwsA(
        isA<ServerRequestException>().having(
          (e) => e.message,
          'message',
          contains('without a session token'),
        ),
      ),
    );
  });

  test('an unreachable server is reported as offline, not as a bad password',
      () async {
    await server.close(force: true);

    await expectLater(
      client.signIn(email: 'owner@apexbooks.in', password: 'longenough'),
      throwsA(
        isA<ServerRequestException>()
            .having((e) => e.statusCode, 'statusCode', null)
            .having((e) => e.signedOut, 'signedOut', false)
            .having((e) => e.message, 'message', contains('Could not reach')),
      ),
    );
  });

  test('sign out posts the refresh token', () async {
    body = jsonEncode({'revoked': true});
    await client.signOut(refreshToken: 'refresh-1');
    expect(requests.single.uri.path, '/v1/auth/logout');
    expect((jsonDecode(bodies.single) as Map)['refreshToken'], 'refresh-1');
  });

  test('me reads the account and its firm memberships', () async {
    body = jsonEncode({
      'user': {'id': 'user-1', 'email': 'owner@apexbooks.in'},
      'deviceId': 'device-1',
      'firms': [
        {'firmId': 'firm-1', 'firmName': 'Apex Books', 'role': 'admin'},
      ],
    });

    final account = await client.me(accessToken: 'access-1');
    final request = requests.single;
    expect(request.method, 'GET');
    expect(request.uri.path, '/v1/me');
    expect(request.headers.value('authorization'), 'Bearer access-1');
    expect(account.email, 'owner@apexbooks.in');
    expect(account.firms.single.firmId, 'firm-1');
    expect(account.firms.single.role, 'admin');
  });

  test('registering a firm the server already knows is not an error', () async {
    status = 409;
    body = jsonEncode({
      'error': {'code': 'conflict', 'message': 'That firm already exists.'},
    });

    // Completing normally is the assertion: a retry after a timeout must not
    // fail the sync because the first attempt actually landed.
    await client.registerFirm(
      accessToken: 'access-1',
      firmId: '018f2a3b-4c5d-7e8f-9a0b-1c2d3e4f5a6b',
      name: 'Apex Books',
    );
  });

  test('a locked account is reported, not swallowed', () async {
    status = 403;
    body = jsonEncode({
      'error': {'code': 'forbidden', 'message': 'This account is disabled.'},
    });

    await expectLater(
      client.signIn(email: 'owner@apexbooks.in', password: 'longenough'),
      throwsA(
        isA<ServerRequestException>()
            .having((e) => e.signedOut, 'signedOut', true)
            .having((e) => e.message, 'message', 'This account is disabled.'),
      ),
    );
  });
}
