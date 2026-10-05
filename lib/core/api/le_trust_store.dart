import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

/// A TLS trust store carrying the Let's Encrypt roots, for devices whose own
/// trust store is too old to have them.
///
/// Why this exists: `api.apexbooks.in` is certified from Let's Encrypt's ECDSA
/// hierarchy, whose chain ends at **ISRG Root X2**. A device trusts that chain
/// only if its operating system has shipped ISRG Root X2 — which Android added
/// in 2021 (many phones in the field never received it), and which Windows
/// only gains through root-program updates that an offline shop PC may have
/// missed for years. On such a device every request to the server fails as
/// `HandshakeException`, which the UI reports as "this device does not trust
/// the server's certificate". The chain itself is fine — `openssl verify`
/// against the roots bundled here accepts the exact chain the server serves —
/// so the fix is to carry the roots with the app instead of depending on the
/// device having them.
///
/// This is not a way to trust something the platform would refuse. It is the
/// standard public Let's Encrypt roots, the same ones Let's Encrypt publishes
/// and browsers ship, so the only change is that a device with a 2015-era
/// trust store validates `api.apexbooks.in` the way a current one already
/// does. Every request is first attempted with the platform's own store,
/// exactly as before — `HttpClient(context: null)` — and the bundled roots
/// are reached only after that attempt failed with a handshake error. A chain
/// that neither store accepts is still rejected, and the caller still sees
/// the same "does not trust" wording.
class LeTrustStore {
  LeTrustStore._();

  /// PEM assets bundled under `assets/certs/` (registered in pubspec.yaml).
  ///
  /// X2 is the one today's chain actually needs. X1 is the compatibility root
  /// for the RSA hierarchy — included because it costs a few kilobytes and
  /// covers a server-side switch back to RSA issuance, which is exactly the
  /// kind of change nobody remembers to ship an app update for.
  static const List<String> _rootAssets = [
    'assets/certs/isrg-root-x1.pem',
    'assets/certs/isrg-root-x2.pem',
  ];

  /// How the PEM assets are read. Production points this at [rootBundle];
  /// the live tests (`le_trust_store_live_test.dart`) run outside the Flutter
  /// engine, where there is no asset bundle, and point it at the files on
  /// disk instead. Never reassign outside a test.
  @visibleForTesting
  static Future<String> Function(String asset) assetLoader =
      rootBundle.loadString;

  /// The context built once per process, on first use.
  static Future<SecurityContext>? _context;

  /// A [SecurityContext] whose trusted roots are exactly the Let's Encrypt
  /// roots bundled with the app.
  ///
  /// Built fresh rather than by mutating [SecurityContext.defaultContext]:
  /// a private context keeps the fallback confined to the requests that ask
  /// for it, whatever mutating the default context ends up doing on the
  /// platform of the day. Failure to load the assets throws — a broken bundle
  /// is a build error that must not be hidden behind a request that "just"
  /// skips the fallback.
  static Future<SecurityContext> context() {
    return _context ??= _build();
  }

  static Future<SecurityContext> _build() async {
    final context = SecurityContext();
    for (final asset in _rootAssets) {
      final pem = await assetLoader(asset);
      // A PEM file is pure ASCII, so codeUnits are the bytes.
      context.setTrustedCertificatesBytes(pem.codeUnits);
    }
    return context;
  }

  /// Runs [attempt], retrying once with the bundled roots if the platform's
  /// own trust store refused the server's certificate.
  ///
  /// [attempt] receives the [SecurityContext] to construct its
  /// `HttpClient(context:)` with: null on the first attempt, meaning the
  /// platform store; the bundled Let's Encrypt roots on the retry. Each
  /// attempt builds its own client, so a half-used connection from the failed
  /// attempt cannot leak into the second one.
  ///
  /// The retry exists for one situation: a valid chain the device happens not
  /// to have the root for. Only [HandshakeException] triggers it, and only
  /// after the default attempt failed — normal requests behave exactly as
  /// before, and a server presenting a certificate nobody trusts still fails,
  /// on the second attempt instead of the first.
  static Future<T> run<T>(
    Future<T> Function(SecurityContext? tlsContext) attempt,
  ) async {
    try {
      return await attempt(null);
    } on HandshakeException {
      // A certificate that is expired or otherwise invalid in a way time
      // cannot fix will fail the retry too; the first error is the honest
      // one, and it propagates from below when the retry fails again.
      final tlsContext = await context();
      return await attempt(tlsContext);
    }
  }
}
