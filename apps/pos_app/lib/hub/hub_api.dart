import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
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

  /// Owner / Restaurant Admin adds a person (name, email, role, pin). Needs internet on the main device.
  Future<Json> addStaff(Json body);

  /// An owner-console session (refresh token) for the owner / Restaurant Admin signed in here. Needs internet.
  Future<Json> consoleSession();
  Future<Json> login(String userId, String pin);
  Future<Json> state();

  /// Restaurant + branch header ({tenant: {name, gstin, address}, branch: {name, code}}).
  Future<Json> branch();
  Future<Json> menu();
  Future<Json> toggleItemAvailability(String itemId);
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

  /// The owner chose this device in the console as the new main device: {pending, code, cloudUrl} from the hub.
  Future<Json> promotion();
  Stream<Json> events();

  /// Menu photo bytes from the hub (cached there for offline use); null if there is none.
  Future<Uint8List?> media(String id);

  // kitchen display (K1)
  Future<List<Json>> kdsTickets();
  Future<Json> setTicketStatus(String ticketId, String status);

  // reports, printing, adjustments
  Future<List<Json>> tips();

  /// Prints a bill (reprints are marked DUPLICATE by the hub). Returns `status`: printed | pdf | no_printer.
  Future<Json> printBill(String billId, {bool ifPrinter = false});
  Future<Json> reprintKot(String ticketId);
  Future<Json> printers();
  Future<Json> savePrinters(Json settings);
  Future<Json> testPrint(String target);
  Future<Json> adjust(String billId, {required int amountPaise, required String reason, String? approverUserId, String? approverPin});
}

/// One idempotency key per payment *attempt*: retries of the same attempt reuse it, so a dropped
/// response can never charge twice (AC-07).
String newIdempotencyKey() {
  final r = Random.secure();
  return 'pos-${DateTime.now().microsecondsSinceEpoch}-${List.generate(8, (_) => r.nextInt(36).toRadixString(36)).join()}';
}

/// Talks to the branch hub over whichever route works: the hub's addresses on the restaurant network (Wi-Fi,
/// Ethernet, a VPN such as Tailscale) first, then the cloud relay ([relayUrl]) for a floor on another router / ISP.
/// Routes it learns from the hub (`/pairing/info`) or finds again after the hub's IP changed go to [onRoutes].
class HttpHubApi extends HubApi {
  HttpHubApi({required this.baseUrl, required this.deviceToken, String? certFingerprint, http.Client? client, List<String> alternates = const [],
      String? relayUrl, this.onRoutes, Future<List<ProbedHub>> Function()? scan})
      : _fingerprint = certFingerprint,
        _http = client ?? pinnedHttpClient(certFingerprint),
        _lan = {baseUrl, ...alternates}.toList(),
        _relay = relayUrl,
        _scan = scan ?? probeHubs;

  final String baseUrl; // https://192.168.1.10:8443/hub/v1
  final String deviceToken;
  final String? _fingerprint;
  final http.Client _http;
  final List<String> _lan;
  String? _relay; // https://api.example.com/api/v1/relay/b/<branchId>/hub/v1
  final void Function(List<String> lan, String? relay)? onRoutes;
  final Future<List<ProbedHub>> Function() _scan;

  String? _active;
  Future<String>? _picking;
  bool _learned = false;
  DateTime _lanCheckedAt = DateTime.now();
  DateTime? _scannedAt;

  /// The route in use right now (null until the first request picks one).
  String? get activeUrl => _active;
  bool get viaRelay => _active != null && _active == _relay;

  bool get _single => _lan.length == 1 && _relay == null;

  Future<String> _route() {
    final a = _active;
    if (a != null) {
      // on the relay: look for the restaurant network again now and then (back on the main device's Wi-Fi)
      if (a == _relay && DateTime.now().difference(_lanCheckedAt) > const Duration(seconds: 60)) {
        _lanCheckedAt = DateTime.now();
        unawaited(_firstLan().then((u) {
          if (u != null) _active = u;
        }));
      }
      return Future.value(a);
    }
    if (_single) return Future.value(_active = baseUrl); // one address, no relay: exactly as before
    return _picking ??= _pick().whenComplete(() => _picking = null);
  }

  /// The first hub address that answers /health (all tried at once, so a dead address costs no extra time).
  Future<String?> _firstLan() {
    final c = Completer<String?>();
    var left = _lan.length;
    if (left == 0) return Future.value(null);
    for (final u in List.of(_lan)) {
      _http.get(Uri.parse('$u/health')).timeout(const Duration(seconds: 4)).then((r) {
        if (r.statusCode == 200 && !c.isCompleted) c.complete(u);
      }, onError: (_) {}).whenComplete(() {
        if (--left == 0 && !c.isCompleted) c.complete(null);
      });
    }
    return c.future;
  }

  Future<String> _pick() async {
    final lan = await _firstLan();
    _lanCheckedAt = DateTime.now();
    final pick = lan ?? _relay;
    if (pick == null) {
      unawaited(_rediscover());
      throw HubApiException(0, 'hub_offline', 'Kitchen hub offline');
    }
    if (lan == null) unawaited(_rediscover());
    _active = pick;
    unawaited(_learn(pick));
    return pick;
  }

  /// The hub's other addresses and its cloud relay, from the hub itself (once per connection).
  Future<void> _learn(String base) async {
    if (_learned || onRoutes == null) return;
    _learned = true;
    try {
      final r = await _http.get(Uri.parse('$base/pairing/info')).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return;
      final j = jsonDecode(r.body) as Json;
      if (_fingerprint != null && j['certFingerprint'] != null && j['certFingerprint'] != _fingerprint) return;
      final port = Uri.parse(baseUrl).port;
      var changed = false;
      for (final a in (j['addresses'] as List? ?? const [])) {
        final u = 'https://$a:$port/hub/v1';
        if (!_lan.contains(u)) {
          _lan.add(u);
          changed = true;
        }
      }
      final cloud = j['cloudUrl'], branch = j['branchId'];
      if (cloud is String && cloud.isNotEmpty && branch is String) {
        final relay = relayUrlFor(cloud, branch);
        if (relay != _relay) {
          _relay = relay;
          changed = true;
        }
      }
      if (changed) onRoutes!(List.unmodifiable(_lan.where((u) => u != baseUrl)), _relay);
    } catch (_) {
      _learned = false; // try again on the next connection
    }
  }

  /// Nothing answered on the known addresses: the main device may have a new IP on this Wi-Fi. Scan for the same
  /// certificate (at most every 2 minutes).
  Future<void> _rediscover() async {
    final fp = _fingerprint;
    if (fp == null || onRoutes == null) return;
    final last = _scannedAt;
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 2)) return;
    _scannedAt = DateTime.now();
    try {
      for (final h in await _scan()) {
        if (h.fingerprint != fp) continue;
        final u = 'https://${h.host}:${h.port}/hub/v1';
        if (!_lan.contains(u)) _lan.insert(0, u);
        _active = u;
        onRoutes!(List.unmodifiable(_lan.where((x) => x != baseUrl)), _relay);
        return;
      }
    } catch (_) {}
  }

  /// One request over the current route; a route that cannot be reached is dropped and the next one tried once.
  /// A request that may have reached the hub (timed out after sending) is retried only when it is a read.
  Future<http.Response> _request(String method, String path, {String? body, Map<String, String>? extra, required Duration timeout}) async {
    for (var attempt = 0;; attempt++) {
      final base = await _route();
      final relay = base == _relay;
      final req = http.Request(method, Uri.parse('$base$path'))..headers.addAll({..._h, ...?extra});
      if (relay) req.headers['x-relay-timeout'] = '${timeout.inSeconds < 20 ? 20 : timeout.inSeconds}';
      if (body != null) req.body = body;
      final wait = relay ? Duration(seconds: (timeout.inSeconds < 20 ? 20 : timeout.inSeconds) + 5) : timeout;
      Object? failure;
      http.Response? res;
      try {
        res = await http.Response.fromStream(await _http.send(req).timeout(wait));
      } catch (e) {
        failure = e;
      }
      // the relay answers for the hub when the hub is not connected to it
      final relayDown = relay && res != null && res.statusCode == 503 && res.body.contains('hub_offline');
      if (res != null && !relayDown) return res;
      if (_active == base) _active = null;
      final canRetry = attempt == 0 && !_single && (method == 'GET' || failure is! TimeoutException || relayDown);
      if (!canRetry) throw HubApiException(0, 'hub_offline', 'Kitchen hub offline');
    }
  }

  Map<String, String> get _h => {
        'content-type': 'application/json',
        'x-device-token': deviceToken,
        if (sessionToken != null) 'authorization': 'Bearer $sessionToken',
      };

  /// Print routes answer JSON when the printer took the job, otherwise the PDF itself (no printer / unreachable).
  Future<Json> _print(String path, Object body) async {
    final res = await _request('POST', path, body: jsonEncode(body), timeout: const Duration(seconds: 15));
    if ((res.headers['content-type'] ?? '').startsWith('application/pdf')) {
      return {'status': 'pdf', 'error': res.headers['x-print-error'], 'copyNo': int.tryParse(res.headers['x-print-copy'] ?? ''), 'pdfBytes': res.bodyBytes.length, 'pdf': res.bodyBytes};
    }
    final decoded = res.body.isEmpty ? const <String, dynamic>{} : jsonDecode(utf8.decode(res.bodyBytes)) as Json;
    if (res.statusCode >= 400) throw HubApiException(res.statusCode, '${decoded['code'] ?? 'error'}', '${decoded['message'] ?? 'Print failed'}');
    return decoded;
  }

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, String>? extra, Duration timeout = const Duration(seconds: 8)}) async {
    final res = await _request(method, path, body: body == null ? null : jsonEncode(body), extra: extra, timeout: timeout);
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
  Future<Json> addStaff(Json body) async => await _send('POST', '/staff', body: body) as Json;

  @override
  // the main device asks the cloud, which can take most of a minute to wake up (free hosting): wait for it
  Future<Json> consoleSession() async => await _send('POST', '/console-session', body: const {}, timeout: const Duration(seconds: 90)) as Json;

  @override
  Future<Json> login(String userId, String pin) async {
    final r = await _send('POST', '/session/login', body: {'userId': userId, 'pin': pin}) as Json;
    sessionToken = r['sessionToken'] as String;
    return r;
  }

  @override
  Future<Json> state() async => await _send('GET', '/state') as Json;
  @override
  Future<Json> branch() async => await _send('GET', '/branch') as Json;
  @override
  Future<Json> menu() async => await _send('GET', '/menu') as Json;
  @override
  Future<Json> toggleItemAvailability(String itemId) async =>
      await _send('POST', '/menu/items/$itemId/toggle-availability') as Json;
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
  Future<Json> promotion() async => await _send('GET', '/promotion') as Json;

  @override
  Future<Uint8List?> media(String id) async {
    try {
      // through the relay, photos come straight from the cloud (they are public there) instead of via the hub
      final relay = viaRelay ? _relay : null;
      final res = relay != null
          ? await _http.get(Uri.parse('${relay.substring(0, relay.indexOf('/relay/b/'))}/media/$id')).timeout(const Duration(seconds: 20))
          : await _request('GET', '/media/$id', timeout: const Duration(seconds: 15));
      return res.statusCode == 200 ? res.bodyBytes : null;
    } catch (_) {
      return null; // a missing photo never breaks the menu: the plate illustration shows instead
    }
  }

  @override
  Future<List<Json>> kdsTickets() async => (await _send('GET', '/kds/tickets') as List).cast<Json>();
  @override
  Future<Json> setTicketStatus(String ticketId, String status) async => await _send('POST', '/kds/tickets/$ticketId/status', body: {'status': status}) as Json;
  @override
  Future<List<Json>> tips() async => (await _send('GET', '/reports/tips') as List).cast<Json>();
  @override
  Future<Json> printBill(String billId, {bool ifPrinter = false}) => _print('/bills/$billId/print', {'ifPrinter': ifPrinter});
  @override
  Future<Json> reprintKot(String ticketId) => _print('/kot/$ticketId/print', const {});
  @override
  Future<Json> printers() async => await _send('GET', '/printers') as Json;
  @override
  Future<Json> savePrinters(Json settings) async => await _send('PUT', '/printers', body: settings) as Json;
  @override
  Future<Json> testPrint(String target) async => await _send('POST', '/printers/$target/test') as Json;
  @override
  Future<Json> adjust(String billId, {required int amountPaise, required String reason, String? approverUserId, String? approverPin}) async =>
      await _send('POST', '/bills/$billId/adjustments',
          body: {'amountPaise': amountPaise, 'reason': reason, 'approverUserId': ?approverUserId, 'approverPin': ?approverPin}) as Json;

  @override
  Stream<Json> events() async* {
    final base = await _route();
    if (base == _relay) {
      yield* _relayEvents(base);
      return;
    }
    final ws = connectPinnedWebSocket(Uri.parse('${base.replaceFirst('http', 'ws')}/events?deviceToken=${Uri.encodeQueryComponent(deviceToken)}'), _fingerprint);
    yield* ws.stream.map((m) => jsonDecode(m as String) as Json);
  }

  /// Live events through the cloud relay (long-poll): the state first, then each change. Ends when the restaurant
  /// network is reachable again, so the caller reconnects over the WebSocket.
  Stream<Json> _relayEvents(String relay) async* {
    final url = '${relay.substring(0, relay.length - '/hub/v1'.length)}/events';
    Future<Json> poll(int? after) async {
      final res = await _http.get(Uri.parse(after == null ? url : '$url?after=$after'), headers: _h).timeout(const Duration(seconds: 40));
      if (res.statusCode != 200) {
        if (_active == relay) _active = null;
        throw HubApiException(res.statusCode, 'hub_offline', 'Kitchen hub offline');
      }
      return jsonDecode(res.body) as Json;
    }

    Future<Json> snapshot() async => {'type': 'state.snapshot', 'at': DateTime.now().toUtc().toIso8601String(), 'data': await state()};
    var p = await poll(null);
    var seq = p['seq'] as int;
    yield await snapshot();
    while (_active == relay) {
      p = await poll(seq);
      if (p['reset'] == true) {
        yield await snapshot();
      } else {
        for (final e in (p['events'] as List? ?? const [])) {
          yield (e as Map).cast<String, dynamic>();
        }
      }
      seq = p['seq'] as int;
    }
  }
}

/// The cloud relay address of a branch's main device.
String relayUrlFor(String cloudUrl, String branchId) => '${cloudUrl.replaceAll(RegExp(r'/+$'), '')}/relay/b/$branchId/hub/v1';

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

/// A device that joined the main device: where the hub is, the pinned certificate and this device's token.
class JoinedHub {
  const JoinedHub({required this.baseUrl, required this.deviceToken, required this.fingerprint, this.restaurant, this.userName});
  final String baseUrl, deviceToken, fingerprint;
  final String? restaurant, userName;
}

/// Finds the restaurant's main device on this Wi-Fi and joins it with the person's email + POS PIN (no pairing code,
/// no internet needed). Returns null when no main device answered; throws [HubApiException] when one refused.
/// [host] = an address typed in by hand ("192.168.1.20" or "192.168.1.20:8443") instead of scanning.
Future<JoinedHub?> findAndJoinHub({required String email, required String pin, required String deviceName, required String platform, String? host}) async {
  String? only;
  var port = 8443;
  if (host != null && host.trim().isNotEmpty) {
    final parts = host.trim().split(':');
    only = parts.first;
    if (parts.length > 1) port = int.tryParse(parts[1]) ?? 8443;
  }
  Object? why;
  var hubs = await probeHubs(onlyHost: only, port: port, onError: (e) => why = e);
  if (hubs.isEmpty && only == null && !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    // iPhone: the first scan only brings up the "Local Network" prompt; scan again once it is answered
    await Future<void>.delayed(const Duration(seconds: 2));
    hubs = await probeHubs(port: port);
  }
  if (hubs.isEmpty) {
    if (only == null) return null;
    // a typed address: say what went wrong there instead of "not found"
    throw HubApiException(0, 'hub_unreachable', unreachableHint(only, port, why));
  }
  HubApiException? last;
  for (final h in hubs) {
    final base = 'https://${h.host}:${h.port}/hub/v1';
    final res = await pinnedHttpClient(h.fingerprint).post(Uri.parse('$base/pairing/staff-claim'),
        headers: {'content-type': 'application/json'}, body: jsonEncode({'email': email.trim(), 'pin': pin, 'deviceName': deviceName, 'platform': platform}));
    final body = res.body.isEmpty ? const {} : jsonDecode(res.body) as Map;
    if (res.statusCode == 201) {
      return JoinedHub(baseUrl: base, deviceToken: body['deviceToken'] as String, fingerprint: h.fingerprint,
          restaurant: h.info['restaurant'] as String?, userName: (body['user'] as Map?)?['name'] as String?);
    }
    last = HubApiException(res.statusCode, '${body['code']}', '${body['message'] ?? 'Could not join the main device'}');
    // another restaurant's main device on a shared Wi-Fi does not know this person: try the next one
    if (last.code != 'invalid_credentials') throw last;
  }
  throw last!;
}

/// Why a typed main-device address did not answer, in words the person can act on.
String unreachableHint(String host, int port, Object? error) {
  final e = '${error ?? ''}';
  final ios = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  final permission = ios ? ' On iPhone / iPad: Settings → BhojMitra POS → turn on "Local Network", then try again.' : '';
  if (e.contains('refused')) {
    return 'The device at $host answered, but BhojMitra is not running there. Open BhojMitra POS on the main device and keep it on screen, then try again.$permission';
  }
  if (e.contains('No route') || e.contains('unreachable') || e.contains('errno = 65') || e.contains('errno = 51')) {
    return 'This device cannot reach $host. Check that both are on the same Wi-Fi (not a guest network).$permission';
  }
  return 'No answer from $host:$port. Check the address under More → Hub & devices on the main device, that the main device is '
      'open and on the same Wi-Fi as this one.$permission';
}

/// Opaque helper so the app can show WebSocket channel errors uniformly.
typedef ChannelFactory = WebSocketChannel Function(Uri);
