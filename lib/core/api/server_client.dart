import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_config.dart';

/// What the server had to say about an erasure request.
enum FirmErasure {
  /// The firm was on the server, and is now gone from it.
  erased,

  /// The server had nothing under that id — it was never pushed, or it was
  /// already erased. Reported separately from [erased] because it means the
  /// device was holding a copy the server never had, which is worth knowing
  /// when the two are supposed to be in step. The caller's goal state is the
  /// same either way, so it is not an error.
  alreadyGone,
}

/// A request to the Atria API that failed in a way worth putting in front of a
/// person. Anything not thrown as one of these is a bug, not a condition.
class ServerRequestException implements Exception {
  const ServerRequestException(
    this.message, {
    this.statusCode,
    this.signedOut = false,
  });

  final String message;

  /// Null when the request never got an answer (offline, DNS, timeout).
  final int? statusCode;

  /// The server rejected the session. Separate from a generic failure so the
  /// UI can offer "sign in again" instead of printing a status code.
  final bool signedOut;

  @override
  String toString() => message;
}

/// The Atria API client, for the calls that are not sign-in.
///
/// `dart:io`'s [HttpClient] rather than an HTTP package, for the same reason
/// [ServerProbe] uses it: both mobile and desktop provide it, and the app has no
/// HTTP dependency to justify adding for a handful of requests.
///
/// The base address is resolved per call through [ApiConfig], so changing the
/// server in Settings takes effect on the next request rather than the next
/// launch.
class ServerClient {
  ServerClient(this._config, {this.timeout = const Duration(seconds: 20)});

  final ApiConfig _config;

  /// How long any single step of a request may take before it is abandoned.
  final Duration timeout;

  /// Erases a firm from the server.
  ///
  /// This is the only half of "remove this business" that cannot be done on the
  /// device, and it is a real deletion rather than a tombstone: DPDP Rule 8
  /// wants erasure to erase, and a tombstone is not an erasure. The server also
  /// records the id so a device that was offline when this happened cannot push
  /// the firm back.
  ///
  /// A 404 is treated as success — see [FirmErasure.alreadyGone]. A 401/403 is
  /// surfaced as [ServerRequestException.signedOut] so the UI can say "sign in
  /// again" rather than showing a status code at somebody who just wanted a
  /// business gone.
  Future<FirmErasure> eraseFirm({
    required String firmId,
    required String accessToken,
  }) async {
    final uri = await _config.endpoint('/v1/firms/$firmId');
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.deleteUrl(uri).timeout(timeout);
      request.headers
          .set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);

      switch (response.statusCode) {
        case 200:
          return FirmErasure.erased;
        case 404:
          return FirmErasure.alreadyGone;
        case 401:
        case 403:
          throw const ServerRequestException(
            'Atria no longer accepts this device\'s session. Sign in again, '
            'then retry.',
            signedOut: true,
          );
        default:
          throw ServerRequestException(
            _messageFrom(body) ??
                'The server refused the request (HTTP ${response.statusCode}).',
            statusCode: response.statusCode,
          );
      }
    } on ServerRequestException {
      rethrow;
    } on HandshakeException {
      throw const ServerRequestException(
        'This device does not trust the server\'s certificate, so nothing was '
        'deleted there.',
      );
    } on SocketException {
      throw const ServerRequestException(
        'Could not reach Atria. Check this device is online, then retry.',
      );
    } on TimeoutException {
      throw ServerRequestException(
        'Atria did not answer within ${timeout.inSeconds} seconds, so nothing '
        'was deleted there.',
      );
    } on HttpException catch (error) {
      throw ServerRequestException('The request failed: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// Pulls the server's own message out of the standard error body
  /// (`{"error":{"code","message"}}`).
  ///
  /// Returns null rather than throwing when the body is not that shape: a
  /// proxy's HTML error page is a normal thing to receive and must not turn a
  /// clean failure into a crash.
  static String? _messageFrom(String body) {
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
