import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Verifies the cloud-signed license token OFFLINE: base64url(payload).base64url(Ed25519 signature).
/// The public key is the cloud's LICENSE_PUBLIC_KEY (SPKI DER, base64); the raw key is its last 32 bytes.
class LicenseVerifier {
  LicenseVerifier(String publicKeySpkiB64) : _raw = base64.decode(publicKeySpkiB64).sublist(12);
  final List<int> _raw;

  Future<Map<String, Object?>?> verify(String token) async {
    final parts = token.split('.');
    if (parts.length != 2) return null;
    try {
      final sig = base64Url.decode(base64Url.normalize(parts[1]));
      final ok = await Ed25519().verify(
        utf8.encode(parts[0]),
        signature: Signature(sig, publicKey: SimplePublicKey(_raw, type: KeyPairType.ed25519)),
      );
      if (!ok) return null;
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0])))) as Map<String, Object?>;
      return payload['v'] == 1 ? payload : null;
    } catch (_) {
      return null;
    }
  }
}

enum LicenseState { notStarted, active, grace, readOnly, invalid }

LicenseState licenseState(Map<String, Object?>? p, DateTime now) {
  if (p == null) return LicenseState.invalid;
  final t = now.millisecondsSinceEpoch ~/ 1000;
  final nbf = p['nbf']! as int, exp = p['exp']! as int, grace = p['grace_days']! as int;
  if (t < nbf) return LicenseState.notStarted;
  if (t < exp) return LicenseState.active;
  if (t < exp + grace * 86400) return LicenseState.grace;
  return LicenseState.readOnly;
}
