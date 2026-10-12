import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Verifies an Argon2id PHC string (as produced by the cloud's argon2 library) against a PIN.
/// Format: `$argon2id$v=19$m=<kib>,t=<iterations>,p=<lanes>$<salt b64>$<hash b64>`
bool verifyArgon2(String phc, String secret) {
  final parts = phc.split(r'$');
  if (parts.length != 6 || parts[1] != 'argon2id') return false;
  final params = {for (final kv in parts[3].split(',')) kv.split('=')[0]: int.parse(kv.split('=')[1])};
  final salt = _b64(parts[4]);
  final expected = _b64(parts[5]);
  final gen = Argon2BytesGenerator()
    ..init(Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      salt,
      desiredKeyLength: expected.length,
      iterations: params['t']!,
      memory: params['m']!,
      lanes: params['p']!,
      version: Argon2Parameters.ARGON2_VERSION_13,
    ));
  final out = gen.process(Uint8List.fromList(utf8.encode(secret)));
  if (out.length != expected.length) return false;
  var diff = 0;
  for (var i = 0; i < out.length; i++) {
    diff |= out[i] ^ expected[i];
  }
  return diff == 0;
}

Uint8List _b64(String s) => base64.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));
