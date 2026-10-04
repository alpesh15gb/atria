import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The outcome of asking a server "are you the Apex Books API?".
class ServerProbeResult {
  const ServerProbeResult({required this.ok, required this.message});

  final bool ok;

  /// Wording shown in Settings, so it has to be specific: "something answered"
  /// and "the Apex Books API answered" are different facts, and telling them apart
  /// is the entire point of the check. Pointing the app at a different server
  /// that happens to return 200 for everything is easy to do and impossible to
  /// notice otherwise.
  final String message;
}

/// Asks a server whether it is the Apex Books API.
///
/// Uses `dart:io` rather than adding an HTTP package: the app ships on desktop
/// and mobile, both of which provide `HttpClient`, and this is the first and so
/// far only request the app makes.
class ServerProbe {
  ServerProbe._();

  static Future<ServerProbeResult> check(
    String baseUrl, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final root = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (root.isEmpty) {
      return const ServerProbeResult(
          ok: false, message: 'Enter a server address first.');
    }

    final Uri uri;
    try {
      uri = Uri.parse('$root/health');
    } on FormatException {
      return const ServerProbeResult(
          ok: false, message: 'That is not a usable server address.');
    }

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);

      if (response.statusCode != 200) {
        return ServerProbeResult(
          ok: false,
          message: 'The server answered HTTP ${response.statusCode}. Check the '
              'address has no path after it.',
        );
      }
      return describeHealthBody(body);
    } on HandshakeException {
      // Its own message because it is its own fix — a self-signed or expired
      // certificate is not a typo in the address, and retyping will not help.
      return const ServerProbeResult(
        ok: false,
        message: 'TLS handshake failed, so this device does not trust that '
            "server's certificate.",
      );
    } on SocketException {
      return const ServerProbeResult(
        ok: false,
        message: 'Could not reach that address. Check the spelling, and that '
            'this device is online.',
      );
    } on TimeoutException {
      return ServerProbeResult(
        ok: false,
        message: 'No answer within ${timeout.inSeconds} seconds.',
      );
    } catch (error) {
      return ServerProbeResult(ok: false, message: 'Request failed: $error');
    } finally {
      client.close(force: true);
    }
  }

  /// Interprets a `/health` body.
  ///
  /// Separated from the request so it can be tested without a network: the
  /// interesting cases are all malformed replies, and a unit test is the only
  /// way to produce those on demand.
  ///
  /// `status: ok` alone is *not* enough to pass. The server Apex Books replaced on
  /// `api.apexbooks.in` answered HTTP 200 with exactly `{"status":"ok"}` and
  /// nothing else — so accepting that would have reported a healthy connection
  /// to a different application, which is precisely the mistake this check is
  /// meant to catch. The version field is the discriminator.
  static ServerProbeResult describeHealthBody(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const ServerProbeResult(
        ok: false,
        message: 'Something answered, but it is not the Apex Books API — the reply '
            'was not JSON.',
      );
    }

    if (decoded is! Map || decoded['status'] != 'ok') {
      return const ServerProbeResult(
        ok: false,
        message: 'Something answered, but it is not the Apex Books API.',
      );
    }

    final version = decoded['version'];
    if (version is! String || version.isEmpty) {
      return const ServerProbeResult(
        ok: false,
        message: 'Something healthy answered, but without the Apex Books API\'s '
            'version — so it is probably a different application.',
      );
    }

    return ServerProbeResult(
      ok: true,
      message: 'Connected to the Apex Books API v$version.',
    );
  }
}
