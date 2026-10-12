import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final _rng = Random.secure();

int _lastMs = -1;
int _seq = 0;

/// RFC 9562 UUIDv7 — time-ordered ids for every hub row and outbox event. Monotonic within a process:
/// ids minted in the same millisecond use a 12-bit counter (method 1, §6.2), so creation order = sort order.
String uuidv7([DateTime? now]) {
  var ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  if (ms <= _lastMs) {
    ms = _lastMs;
    _seq++;
    if (_seq > 0xfff) {
      ms = ++_lastMs;
      _seq = 0;
    }
  } else {
    _seq = _rng.nextInt(0x400); // random start leaves room to count up
  }
  _lastMs = ms;
  final b = Uint8List(16);
  for (var i = 0; i < 6; i++) {
    b[i] = (ms >> (8 * (5 - i))) & 0xff;
  }
  for (var i = 8; i < 16; i++) {
    b[i] = _rng.nextInt(256);
  }
  b[6] = 0x70 | ((_seq >> 8) & 0x0f);
  b[7] = _seq & 0xff;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

String randomToken([int bytes = 32]) => base64Url.encode(List<int>.generate(bytes, (_) => _rng.nextInt(256))).replaceAll('=', '');

/// Six-digit one-time code (pairing).
String randomDigits(int n) => List.generate(n, (_) => _rng.nextInt(10)).join();

String nowIso([DateTime? t]) => (t ?? DateTime.now()).toUtc().toIso8601String();

class HubError implements Exception {
  HubError(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;
  Map<String, Object> toJson() => {'statusCode': status, 'code': code, 'message': message};
  @override
  String toString() => 'HubError($status $code): $message';
}

HubError badRequest(String code, String m) => HubError(400, code, m);
HubError unauthorized([String code = 'unauthorized', String m = 'Unauthorized']) => HubError(401, code, m);
HubError forbidden(String code, String m) => HubError(403, code, m);
HubError notFound(String what) => HubError(404, 'not_found', '$what not found');
HubError conflict(String code, String m) => HubError(409, code, m);
