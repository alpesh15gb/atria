import 'dart:io';

import 'package:atria/core/api/api_config.dart';
import 'package:atria/core/api/server_client.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The erasure call is the one request in the app that destroys something that
/// cannot be restored, so every status it can come back with is worth pinning
/// down — particularly the two that are *not* failures: a 404 (there was
/// nothing there to erase) and a status the server chose to explain.
///
/// A real [HttpServer] on the loopback interface rather than a mocked client:
/// the interesting behaviour is a status code crossing a socket, which is
/// exactly what a mock would replace with an assumption.
void main() {
  const firmId = '018f2a3b-4c5d-7e8f-9a0b-1c2d3e4f5a6b';

  late AppDatabase db;
  late HttpServer server;
  late ServerClient client;
  final requests = <HttpRequest>[];

  // What the fake API answers with. Set per test.
  late int status;
  late String body;

  setUp(() async {
    requests.clear();
    status = 200;
    body = '{"firmId":"$firmId","erased":true}';

    db = AppDatabase.test(NativeDatabase.memory());
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request);
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
    client = ServerClient(
      ApiConfig(settings),
      timeout: const Duration(seconds: 5),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await db.close();
  });

  /// The server's listener runs concurrently with the client's await, so the
  /// recorded request is not guaranteed to be in the list the instant the call
  /// returns. One turn of the event loop is enough.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('asks DELETE /v1/firms/<id> and carries the session', () async {
    await client.eraseFirm(firmId: firmId, accessToken: 'access-1');
    await settle();

    final request = requests.single;
    expect(request.method, 'DELETE');
    expect(request.uri.path, '/v1/firms/$firmId');
    expect(request.headers.value('authorization'), 'Bearer access-1');
  });

  test('a 200 means the server erased it', () async {
    expect(
      await client.eraseFirm(firmId: firmId, accessToken: 'access-1'),
      FirmErasure.erased,
    );
  });

  test('a 404 is success, not failure: there was nothing left to erase',
      () async {
    // Either the business was never pushed, or it was already erased. Both mean
    // the caller's goal state is reached, and treating this as an error would
    // strand somebody with a business they cannot get rid of.
    status = 404;
    body = '{"error":{"code":"not_found","message":"No such business."}}';

    expect(
      await client.eraseFirm(firmId: firmId, accessToken: 'access-1'),
      FirmErasure.alreadyGone,
    );
  });

  test('a rejected session is reported as signed out, not as a status code',
      () async {
    status = 401;
    body = '{"error":{"code":"unauthorized","message":"Authentication is required."}}';

    await expectLater(
      client.eraseFirm(firmId: firmId, accessToken: 'stale'),
      throwsA(isA<ServerRequestException>()
          .having((error) => error.signedOut, 'signedOut', isTrue)),
    );
  });

  test("a failure shows the server's own explanation when there is one",
      () async {
    status = 409;
    body = '{"error":{"code":"conflict","message":'
        '"That business was deleted from Atria."}}';

    await expectLater(
      client.eraseFirm(firmId: firmId, accessToken: 'access-1'),
      throwsA(isA<ServerRequestException>().having(
        (error) => error.message,
        'message',
        contains('deleted from Atria'),
      )),
    );
  });

  test('an HTML error page does not turn a clean failure into a crash',
      () async {
    // A proxy timing out in front of the API answers 502 with HTML, which is a
    // perfectly normal thing to receive.
    status = 502;
    body = '<html><body>502 Bad Gateway</body></html>';

    await expectLater(
      client.eraseFirm(firmId: firmId, accessToken: 'access-1'),
      throwsA(isA<ServerRequestException>().having(
        (error) => error.statusCode,
        'statusCode',
        502,
      )),
    );
  });

  test('an unreachable server reads as offline, not as an error code',
      () async {
    // Bind and release a port, so the address is real and nothing is listening.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = probe.port;
    await probe.close();

    final settings = SettingsRepository(db);
    await settings.set(
      SettingsRepository.kApiBaseUrl,
      'http://127.0.0.1:$closedPort',
    );
    final offline = ServerClient(
      ApiConfig(settings),
      timeout: const Duration(seconds: 5),
    );

    await expectLater(
      offline.eraseFirm(firmId: firmId, accessToken: 'access-1'),
      throwsA(isA<ServerRequestException>().having(
        (error) => error.message,
        'message',
        contains('Could not reach Atria'),
      )),
    );
  });
}
