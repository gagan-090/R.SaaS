import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'pinning.dart';

typedef Json = Map<String, dynamic>;

class HubApiException implements Exception {
  HubApiException(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// Everything a POS screen can ask the branch hub (Build Spec §09). Screens depend on this interface;
/// [HttpHubApi] talks to a real hub, tests use an in-memory fake.
abstract class HubApi {
  String? sessionToken;

  Future<Json> health();
  Future<List<Json>> staff();
  Future<Json> login(String userId, String pin);
  Future<Json> state();
  Future<Json> menu();
  Future<Json> openOrder({required String type, String? tableId, String? waiterId});
  Future<Json> order(String id);
  Future<Json> addLines(String orderId, List<Json> lines);
  Future<Json> updateLine(String orderId, String lineId, {int? qty, String? notes});
  Future<Json> sendKot(String orderId);
  Future<Json> reverseLine(String orderId, String lineId, {required String reason, String? approverUserId, String? approverPin});
  Future<Json> transfer(String orderId, String toTableId);
  Future<Json> bill(String orderId, {Json? discount, String? discountReason});
  Future<Json> pay(String billId, String idempotencyKey, {required String mode, int? amountPaise, int? tenderedPaise, String? reference});
  Future<Json> tip(String billId, {required int amountPaise, String? waiterId});
  Future<List<Json>> bills(DateTime day);
  Future<Json> syncStatus();
  Stream<Json> events();
}

/// One idempotency key per payment *attempt*: retries of the same attempt reuse it, so a dropped
/// response can never charge twice (AC-07).
String newIdempotencyKey() {
  final r = Random.secure();
  return 'pos-${DateTime.now().microsecondsSinceEpoch}-${List.generate(8, (_) => r.nextInt(36).toRadixString(36)).join()}';
}

class HttpHubApi extends HubApi {
  HttpHubApi({required this.baseUrl, required this.deviceToken, String? certFingerprint, http.Client? client})
      : _fingerprint = certFingerprint,
        _http = client ?? pinnedHttpClient(certFingerprint);

  final String baseUrl; // https://192.168.1.10:8443/hub/v1
  final String deviceToken;
  final String? _fingerprint;
  final http.Client _http;

  Map<String, String> get _h => {
        'content-type': 'application/json',
        'x-device-token': deviceToken,
        if (sessionToken != null) 'authorization': 'Bearer $sessionToken',
      };

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, String>? extra}) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'))..headers.addAll({..._h, ...?extra});
    if (body != null) req.body = jsonEncode(body);
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 8)));
    } on TimeoutException {
      throw HubApiException(0, 'hub_offline', 'Kitchen hub offline');
    } catch (e) {
      throw HubApiException(0, 'hub_offline', 'Kitchen hub offline');
    }
    final decoded = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      final m = decoded is Map ? decoded : const {};
      throw HubApiException(res.statusCode, '${m['code'] ?? 'error'}', '${m['message'] ?? 'Request failed'}');
    }
    return decoded;
  }

  @override
  Future<Json> health() async => await _send('GET', '/health') as Json;
  @override
  Future<List<Json>> staff() async => (await _send('GET', '/staff') as List).cast<Json>();
  @override
  Future<Json> login(String userId, String pin) async {
    final r = await _send('POST', '/session/login', body: {'userId': userId, 'pin': pin}) as Json;
    sessionToken = r['sessionToken'] as String;
    return r;
  }

  @override
  Future<Json> state() async => await _send('GET', '/state') as Json;
  @override
  Future<Json> menu() async => await _send('GET', '/menu') as Json;
  @override
  Future<Json> openOrder({required String type, String? tableId, String? waiterId}) async =>
      await _send('POST', '/orders', body: {'type': type, 'tableId': ?tableId, 'waiterId': ?waiterId}) as Json;
  @override
  Future<Json> order(String id) async => await _send('GET', '/orders/$id') as Json;
  @override
  Future<Json> addLines(String orderId, List<Json> lines) async => await _send('POST', '/orders/$orderId/lines', body: {'lines': lines}) as Json;
  @override
  Future<Json> updateLine(String orderId, String lineId, {int? qty, String? notes}) async =>
      await _send('PATCH', '/orders/$orderId/lines/$lineId', body: {'qty': ?qty, 'notes': ?notes}) as Json;
  @override
  Future<Json> sendKot(String orderId) async => await _send('POST', '/orders/$orderId/kot') as Json;
  @override
  Future<Json> reverseLine(String orderId, String lineId, {required String reason, String? approverUserId, String? approverPin}) async =>
      await _send('POST', '/orders/$orderId/lines/$lineId/reverse', body: {'reason': reason, 'approverUserId': ?approverUserId, 'approverPin': ?approverPin}) as Json;
  @override
  Future<Json> transfer(String orderId, String toTableId) async => await _send('POST', '/orders/$orderId/transfer', body: {'toTableId': toTableId}) as Json;
  @override
  Future<Json> bill(String orderId, {Json? discount, String? discountReason}) async =>
      await _send('POST', '/orders/$orderId/bill', body: {'discount': ?discount, 'discountReason': ?discountReason}) as Json;
  @override
  Future<Json> pay(String billId, String idempotencyKey, {required String mode, int? amountPaise, int? tenderedPaise, String? reference}) async =>
      await _send('POST', '/bills/$billId/payments',
          body: {'mode': mode, 'amountPaise': ?amountPaise, 'tenderedPaise': ?tenderedPaise, 'reference': ?reference}, extra: {'idempotency-key': idempotencyKey}) as Json;
  @override
  Future<Json> tip(String billId, {required int amountPaise, String? waiterId}) async =>
      await _send('POST', '/bills/$billId/tip', body: {'amountPaise': amountPaise, 'waiterId': ?waiterId}) as Json;
  @override
  Future<List<Json>> bills(DateTime day) async =>
      (await _send('GET', '/bills?date=${day.toIso8601String().substring(0, 10)}') as List).cast<Json>();
  @override
  Future<Json> syncStatus() async => await _send('GET', '/sync/status') as Json;

  @override
  Stream<Json> events() {
    final ws = connectPinnedWebSocket(Uri.parse('${baseUrl.replaceFirst('http', 'ws')}/events?deviceToken=${Uri.encodeQueryComponent(deviceToken)}'), _fingerprint);
    return ws.stream.map((m) => jsonDecode(m as String) as Json);
  }
}

/// QR payload shown by the hub: `rsaas-hub://pair?h=<ip>&p=<port>&c=<one-time code>&f=<cert fingerprint>`
class PairingPayload {
  const PairingPayload({required this.host, required this.port, required this.code, this.fingerprint});
  final String host;
  final int port;
  final String code;
  final String? fingerprint;

  String get baseUrl => '${fingerprint == null ? 'http' : 'https'}://$host:$port/hub/v1';

  String encode() => Uri(scheme: 'rsaas-hub', host: 'pair', queryParameters: {'h': host, 'p': '$port', 'c': code, 'f': ?fingerprint}).toString();

  static PairingPayload? tryParse(String raw) {
    final u = Uri.tryParse(raw.trim());
    if (u == null || u.scheme != 'rsaas-hub' || u.host != 'pair') return null;
    final q = u.queryParameters;
    final port = int.tryParse(q['p'] ?? '');
    if (q['h'] == null || port == null || q['c'] == null) return null;
    return PairingPayload(host: q['h']!, port: port, code: q['c']!, fingerprint: q['f']);
  }
}

/// Pairs this device with a hub and returns the device token (stored securely by the caller).
Future<String> claimPairing(PairingPayload p, {required String deviceName, required String platform, http.Client? client}) async {
  final c = client ?? pinnedHttpClient(p.fingerprint);
  final res = await c.post(Uri.parse('${p.baseUrl}/pairing/claim'),
      headers: {'content-type': 'application/json'}, body: jsonEncode({'code': p.code, 'deviceName': deviceName, 'platform': platform}));
  final body = res.body.isEmpty ? const {} : jsonDecode(res.body) as Map;
  if (res.statusCode != 201) throw HubApiException(res.statusCode, '${body['code']}', '${body['message'] ?? 'Pairing failed'}');
  return body['deviceToken'] as String;
}

/// Opaque helper so the app can show WebSocket channel errors uniformly.
typedef ChannelFactory = WebSocketChannel Function(Uri);
