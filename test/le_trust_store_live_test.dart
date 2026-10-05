import 'dart:io';

import 'package:atria/core/api/le_trust_store.dart';
import 'package:atria/core/api/server_probe.dart';
import 'package:test/test.dart';

/// The live part of the bundled-roots fallback, against real servers.
///
/// This file deliberately uses `package:test` rather than `package:flutter_test`:
/// once `TestWidgetsFlutterBinding` is initialized it swaps every `HttpClient`
/// for a stub answering 400 — for the rest of the process — and a test that
/// wants real TLS has no clean escape from that. Run with:
///
///     flutter test test/le_trust_store_live_test.dart
///
/// (or `--tags live-tls`); the tag is excluded from every default run in
/// `dart_test.yaml`.
void main() {
  // The production context is built from the app's bundled assets. This file
  // runs without the Flutter engine (on purpose — see the header comment), so
  // the PEMs are read from the checkout on disk instead: same bytes, same
  // fingerprints, no TestWidgetsFlutterBinding, whose HttpClient stub would
  // otherwise swallow every real request.
  setUpAll(() async {
    LeTrustStore.assetLoader = (asset) async =>
        File('assets/certs/${asset.split('/').last}').readAsString();
  });

  test(
    'ServerProbe connects to the production API via the bundled roots',
    () async {
      final result = await ServerProbe.check('https://api.apexbooks.in');
      expect(result.ok, isTrue, reason: result.message);
    },
    timeout: const Timeout(Duration(seconds: 30)),
    tags: 'live-tls',
  );

  test(
    'ServerProbe still refuses a self-signed certificate',
    () async {
      final _SelfSignedServer server;
      try {
        server = await _SelfSignedServer.bind();
      } on StateError catch (e) {
        // A missing openssl is an environment fact, not a verdict on the
        // trust store. Skipping says so; failing would send someone hunting a
        // TLS bug that is not there.
        markTestSkipped(e.message);
        return;
      }
      try {
        final result = await ServerProbe.check(
          'https://127.0.0.1:${server.port}',
        );
        expect(result.ok, isFalse, reason: result.message);
        expect(result.message, contains('does not trust'));
      } finally {
        await server.forceClose();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
    tags: 'live-tls',
  );
}

/// Where `openssl` lives on this machine.
///
/// `dart:io` cannot mint a certificate, so the negative case has to shell out.
/// It is not always on PATH — Git for Windows ships one under `usr/bin` and
/// installs that directory for its own tools without adding `openssl.exe`
/// itself, which is why this test failed with "cannot find the file" on a
/// machine that demonstrably has openssl. Skips the test with a clear reason
/// when it is genuinely absent, rather than reporting a missing dependency as
/// a broken trust store.
Future<String> _openssl() async {
  const candidates = [
    r'C:\Program Files\Git\usr\bin\openssl.exe',
    r'C:\Program Files\Git\mingw64\bin\openssl.exe',
    r'C:\Program Files (x86)\Git\usr\bin\openssl.exe',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  for (final entry in (Platform.environment['PATH'] ?? '').split(';')) {
    if (entry.isEmpty) continue;
    final path = '$entry\\openssl.exe';
    if (File(path).existsSync()) return path;
  }
  throw StateError(
    'openssl was not found on this machine. The self-signed negative case '
    'needs it to mint a certificate; install Git for Windows or openssl and '
    're-run with `--tags live-tls`.',
  );
}

/// An HTTPS server presenting a self-signed certificate, for the negative
/// case: the fallback must make *valid* chains work, not make everything
/// connect. On a device without the Let's Encrypt roots in its own store the
/// impostor is exactly as untrustworthy as the real server once was — which
/// is the point: only the bundled roots may not be the difference.
class _SelfSignedServer {
  _SelfSignedServer._(this._server, this._dir);

  static Future<_SelfSignedServer> bind() async {
    // dart:io cannot mint a certificate; shell out to openssl, which the
    // test host has (the same tool the repo's cert tooling assumes).
    final dir = await Directory.systemTemp.createTemp('apex_selfsigned');
    final key = File('${dir.path}/key.pem');
    final cert = File('${dir.path}/cert.pem');
    final proc = await Process.run(await _openssl(), [
      'req', '-x509', '-newkey', 'rsa:2048', '-keyout', key.path,
      '-out', cert.path, '-days', '1', '-nodes',
      '-subj', '/CN=not-apexbooks.example',
    ]);
    if (proc.exitCode != 0) {
      throw StateError('openssl failed: ${proc.stderr}');
    }
    final context = SecurityContext()
      ..usePrivateKeyBytes(key.readAsBytesSync())
      ..useCertificateChainBytes(cert.readAsBytesSync());
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((request) async {
      request.response.write('{"status":"ok","version":"impostor"}');
      await request.response.close();
    });
    return _SelfSignedServer._(server, dir);
  }

  final HttpServer _server;
  final Directory _dir;

  int get port => _server.port;

  Future<void> forceClose() async {
    await _server.close(force: true);
    try {
      await _dir.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps an open handle briefly; the temp cleaner will collect it.
    }
  }
}
