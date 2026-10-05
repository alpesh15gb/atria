import 'dart:convert';
import 'dart:io';

import 'package:atria/core/api/le_trust_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The deterministic part of the bundled-roots fallback: the assets parse,
/// they are the certificates they claim to be, and the context is cached.
///
/// The live behaviour — real TLS against real servers, including the negative
/// case against a self-signed impostor — lives in
/// `test/le_trust_store_live_test.dart`, which deliberately avoids
/// [TestWidgetsFlutterBinding]: once initialized, the binding swaps every
/// `HttpClient` for a stub answering 400 for the rest of the process, and
/// there is no clean escape from that for a test that wants the network.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('context() builds once and is cached', () async {
    final a = await LeTrustStore.context();
    final b = await LeTrustStore.context();
    expect(identical(a, b), isTrue);
  });

  for (final asset in const [
    'assets/certs/isrg-root-x1.pem',
    'assets/certs/isrg-root-x2.pem',
  ]) {
    test('$asset parses as X.509', () async {
      final pem = await rootBundle.loadString(asset);
      expect(pem, contains('-----BEGIN CERTIFICATE-----'));
      // If the bundle were corrupted — or an HTML error page — loading it as
      // trust anchors is exactly what would throw.
      final context = SecurityContext();
      context.setTrustedCertificatesBytes(pem.codeUnits);
    });
  }

  test('the files are the roots they claim to be (fingerprint-pinned)',
      () async {
    // SHA-256 of the DER body — exactly what `openssl x509 -fingerprint
    // -sha256` prints — cross-checked against the values Let's Encrypt
    // publishes. If an asset is ever swapped or corrupted, this fails loudly
    // rather than silently changing what the app will trust.
    const expectedFingerprints = {
      'assets/certs/isrg-root-x1.pem':
          '96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6',
      'assets/certs/isrg-root-x2.pem':
          '69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470',
    };
    for (final entry in expectedFingerprints.entries) {
      final pem = await rootBundle.loadString(entry.key);
      final b64 = pem
          .split('-----BEGIN CERTIFICATE-----')
          .last
          .split('-----END CERTIFICATE-----')
          .first
          .replaceAll(RegExp(r'\s'), '');
      final der = base64Decode(b64);
      expect(sha256.convert(der).toString(), entry.value,
          reason: '${entry.key} is not the certificate it claims to be');
    }
  });
}
