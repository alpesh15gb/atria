import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'le_trust_store.dart';
import 'server_client.dart' show ServerRequestException;

/// The one way this app talks to the Apex Books API.
///
/// [ServerClient] predates this helper and keeps its own copy of the error
/// mapping; everything added since (sign-in, the sync push) goes through here
/// so a new endpoint cannot invent its own failure semantics. The three
/// outcomes worth distinguishing are the same everywhere:
///
/// * the request never got an answer (offline, DNS, timeout) —
///   [ServerRequestException.statusCode] is null and the message says so;
/// * the server answered with a refusal — the status and the server's own
///   message are carried through;
/// * the server rejected the session — [ServerRequestException.signedOut],
///   which the UI turns into "sign in again" rather than an HTTP code.
///
/// `dart:io`'s [HttpClient] rather than an HTTP package, for the same reason
/// the rest of the API layer uses it: both mobile and desktop provide it and
/// the app has no HTTP dependency to justify adding for a handful of calls.
class ServerHttp {
  ServerHttp._();

  /// Performs one JSON request and returns the decoded object body.
  ///
  /// Returns an empty map for a 204/205 or an empty body, so a caller that only
  /// cares whether the call succeeded does not have to special-case it.
  static Future<Map<String, Object?>> requestJson({
    required Uri uri,
    String method = 'POST',
    String? accessToken,
    Object? body,
    Duration timeout = const Duration(seconds: 20),
    String? timeoutMessage,
  }) async {
    try {
      // First attempt with the platform's own trust store; on a handshake
      // failure, retried once with the bundled Let's Encrypt roots (see
      // [LeTrustStore]). A device whose trust store predates ISRG Root X2 —
      // common on phones that stopped receiving updates — then connects
      // instead of dead-ending on a certificate the server cannot be talked
      // out of. Anything neither store accepts still lands in the
      // HandshakeException arm below.
      return await LeTrustStore.run((tlsContext) async {
        final client = HttpClient(context: tlsContext)
          ..connectionTimeout = timeout;
        try {
          final request = await client.openUrl(method, uri).timeout(timeout);
          request.headers.set(HttpHeaders.acceptHeader, 'application/json');
          if (accessToken != null && accessToken.trim().isNotEmpty) {
            request.headers
                .set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
          }
          if (body != null) {
            final encoded = utf8.encode(jsonEncode(body));
            request.headers.contentType = ContentType.json;
            request.headers.contentLength = encoded.length;
            request.add(encoded);
          }

          final response = await request.close().timeout(timeout);
          final raw =
              await response.transform(utf8.decoder).join().timeout(timeout);
          final status = response.statusCode;

          if (status >= 200 && status < 300) {
            if (raw.trim().isEmpty) return const <String, Object?>{};
            final decoded = jsonDecode(raw);
            if (decoded is Map) return decoded.cast<String, Object?>();
            // A success that is not a JSON object means the address is not the
            // Apex Books API — most likely a proxy or a captive portal answering 200
            // with HTML. Failing here is far better than a null-pointer later.
            throw const ServerRequestException(
              'The server answered, but not in the shape Apex Books expects. Check the '
              'server address in Settings.',
            );
          }

          if (status == 401 || status == 403) {
            throw ServerRequestException(
              messageFrom(raw) ??
                  'Apex Books no longer accepts this device\'s session. Sign in again, '
                      'then retry.',
              statusCode: status,
              signedOut: true,
            );
          }

          throw ServerRequestException(
            messageFrom(raw) ?? 'The server refused the request (HTTP $status).',
            statusCode: status,
          );
        } finally {
          client.close(force: true);
        }
      });
    } on ServerRequestException {
      rethrow;
    } on HandshakeException {
      // Reached only when neither the platform's roots nor the bundled
      // Let's Encrypt roots accepted the chain — a self-signed or expired
      // certificate, not a missing root.
      throw const ServerRequestException(
        'This device does not trust the server\'s certificate. Nothing was '
        'sent.',
      );
    } on SocketException {
      throw const ServerRequestException(
        'Could not reach Apex Books. Check this device is online, then retry.',
      );
    } on TimeoutException {
      throw ServerRequestException(
        timeoutMessage ??
            'Apex Books did not answer within ${timeout.inSeconds} seconds.',
      );
    } on FormatException catch (error) {
      throw ServerRequestException(
        'The server sent something Apex Books could not read (${error.message}). '
        'Check the server address in Settings.',
      );
    } on HttpException catch (error) {
      throw ServerRequestException('The request failed: ${error.message}');
    }
  }

  /// Pulls the server's own message out of the standard error body
  /// (`{"error":{"code","message"}}`).
  ///
  /// Returns null rather than throwing when the body is not that shape: a
  /// proxy's HTML error page is a normal thing to receive and must not turn a
  /// clean failure into a crash.
  static String? messageFrom(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          final message = error['message'];
          if (message is String && message.trim().isNotEmpty) {
            return message.trim();
          }
        }
      }
    } on FormatException {
      // Not JSON. Fall through to the caller's generic wording.
    }
    return null;
  }
}
