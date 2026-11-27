import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

import 'hub_service.dart';

/// Header the hub adds to every request that came through the cloud relay (never taken from the device).
const relayHeader = 'x-rsaas-relay';

/// Serves devices that cannot reach this main device on the restaurant network (another floor on another router / ISP)
/// through the cloud: long-polls `/relay/hub/poll`, runs each request through the hub's own [handler] (same checks as
/// on the Wi-Fi) and posts the answers back. While relay devices are listening, live events are forwarded too.
/// Offline it just keeps retrying; billing on the Wi-Fi never depends on it.
class RelayClient {
  RelayClient(this.cloudUrl, this.deviceToken, this.handler, {this.events, this.branchId, http.Client? client}) : _http = client ?? http.Client();

  final String cloudUrl; // https://api.example.com/api/v1
  final String deviceToken;
  final Handler handler;
  final Stream<HubEvent>? events;
  final String? branchId;
  final http.Client _http;

  bool _running = false;
  bool _listeners = false;
  StreamSubscription<HubEvent>? _sub;
  final _outEvents = <Map<String, Object?>>[];
  Timer? _flush;

  Map<String, String> get _h => {'x-device-token': deviceToken, 'content-type': 'application/json'};

  void start() {
    if (_running) return;
    _running = true;
    _sub = events?.listen((e) {
      if (!_listeners) return;
      _outEvents.add(e.toJson(branchId ?? ''));
      _flush ??= Timer(const Duration(milliseconds: 200), _sendEvents);
    });
    unawaited(_loop());
  }

  void stop() {
    _running = false;
    _sub?.cancel();
    _flush?.cancel();
    _http.close();
  }

  Future<void> _loop() async {
    var backoff = 2;
    while (_running) {
      try {
        final r = await _http.post(Uri.parse('$cloudUrl/relay/hub/poll'), headers: _h).timeout(const Duration(seconds: 40));
        if (r.statusCode == 401) {
          backoff = 300; // not (or no longer) the main device in the cloud: check back rarely
          throw StateError('relay refused');
        }
        if (r.statusCode != 200) throw StateError('relay ${r.statusCode}');
        final j = jsonDecode(r.body) as Map<String, Object?>;
        _listeners = j['listeners'] == true;
        for (final q in (j['requests'] as List? ?? const [])) {
          unawaited(_serve((q as Map).cast<String, Object?>()));
        }
        backoff = 2;
      } catch (_) {
        if (!_running) return;
        await Future<void>.delayed(Duration(seconds: backoff));
        if (backoff < 60) backoff = backoff * 2 > 60 ? 60 : backoff * 2;
      }
    }
  }

  /// One relayed request through the hub's own pipeline.
  Future<Map<String, Object?>> handle(Map<String, Object?> q) async {
    final headers = <String, String>{
      for (final e in ((q['headers'] as Map?) ?? const {}).entries)
        if (e.key != relayHeader) '${e.key}': '${e.value}',
      relayHeader: '1',
    };
    Response res;
    try {
      res = await handler(Request('${q['method']}', Uri.parse('http://relay/hub/v1/${q['path']}'), headers: headers, body: q['body'] as String?));
    } catch (_) {
      res = Response.internalServerError(body: jsonEncode({'statusCode': 500, 'code': 'internal', 'message': 'Internal error'}), headers: {'content-type': 'application/json'});
    }
    final bytes = await res.read().fold<List<int>>([], (a, b) => a..addAll(b));
    return {
      'id': q['id'],
      'status': res.statusCode,
      'headers': {for (final e in res.headers.entries) if (e.key == 'content-type' || e.key.startsWith('x-print-')) e.key: e.value},
      if (bytes.isNotEmpty) 'bodyB64': base64Encode(bytes),
    };
  }

  Future<void> _serve(Map<String, Object?> q) async {
    final answer = await handle(q);
    for (var i = 0; i < 2; i++) {
      try {
        final r = await _http.post(Uri.parse('$cloudUrl/relay/hub/reply'), headers: _h, body: jsonEncode({'responses': [answer]})).timeout(const Duration(seconds: 20));
        if (r.statusCode == 200) return;
      } catch (_) {}
    }
  }

  Future<void> _sendEvents() async {
    _flush = null;
    if (_outEvents.isEmpty) return;
    final batch = _outEvents.take(200).toList();
    _outEvents.removeRange(0, batch.length);
    try {
      await _http.post(Uri.parse('$cloudUrl/relay/hub/reply'), headers: _h, body: jsonEncode({'events': batch})).timeout(const Duration(seconds: 20));
    } catch (_) {
      // a relay device that misses events reloads the state on its next poll (reset)
    }
    if (_outEvents.isNotEmpty) _flush ??= Timer(const Duration(milliseconds: 200), _sendEvents);
  }
}
