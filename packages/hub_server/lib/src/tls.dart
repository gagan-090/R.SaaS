import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart' as c;

/// Self-signed certificate for the hub's LAN HTTPS. Clients pin [fingerprint] (shown in the pairing QR),
/// so no public CA is involved and a different machine on the Wi-Fi cannot impersonate the hub.
class HubTls {
  HubTls(this.certPem, this.keyPem) : fingerprint = fingerprintOf(certPem);

  final String certPem;
  final String keyPem;
  final String fingerprint;

  static HubTls generate({String commonName = 'rsaas-hub', int days = 3650}) {
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final priv = pair.privateKey as RSAPrivateKey;
    final pub = pair.publicKey as RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem({'CN': commonName, 'O': 'Restaurant SaaS hub'}, priv, pub);
    final cert = X509Utils.generateSelfSignedCertificate(priv, csr, days);
    return HubTls(cert, CryptoUtils.encodeRSAPrivateKeyToPem(priv));
  }

  /// SHA-256 over the DER certificate, hex with colons (what the client compares at pairing).
  static String fingerprintOf(String certPem) => formatFingerprint(c.sha256.convert(CryptoUtils.getBytesFromPEMString(certPem)).bytes);

  static String formatFingerprint(List<int> digest) => digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':').toUpperCase();

  SecurityContext context() => SecurityContext()
    ..useCertificateChainBytes(certPem.codeUnits)
    ..usePrivateKeyBytes(keyPem.codeUnits);

  /// Client-side pinning: accept the hub's self-signed cert only if its fingerprint matches the paired one.
  static HttpClient pinnedClient(String expectedFingerprint) => HttpClient()
    ..badCertificateCallback = (cert, host, port) => formatFingerprint(c.sha256.convert(cert.der).bytes) == expectedFingerprint;
}
