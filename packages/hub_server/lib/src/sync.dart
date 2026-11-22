import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'db.dart';
import 'hub_service.dart';
import 'util.dart';

/// HTTP client for the cloud sync endpoints, authenticated with the hub's cloud device token.
class CloudClient {
  CloudClient(this.baseUrl, this.deviceToken, {http.Client? client}) : _http = client ?? http.Client();
  final String baseUrl; // e.g. https://api.example.com/api/v1
  final String deviceToken;
  final http.Client _http;

  Map<String, String> get _h => {'X-Device-Token': deviceToken, 'Content-Type': 'application/json'};

  Future<Map<String, Object?>> pull(String since) async {
    final r = await _http.get(Uri.parse('$baseUrl/sync/pull?since=$since'), headers: _h).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw http.ClientException('pull failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, Object?>;
  }

  /// A public menu photo, or null if it is gone (404) — throws while offline so callers can retry later.
  Future<({String contentType, Uint8List bytes})?> media(String id) async {
    final r = await _http.get(Uri.parse('$baseUrl/media/$id')).timeout(const Duration(seconds: 20));
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) throw http.ClientException('media failed: ${r.statusCode}');
    return (contentType: r.headers['content-type'] ?? 'image/jpeg', bytes: r.bodyBytes);
  }

  /// Adds a person for the owner / admin signed in on the hub (POST /sync/staff). Needs internet: the cloud checks
  /// the email is unused and the plan's staff limit. Cloud refusals come back as [HubError] with the cloud's message.
  Future<Map<String, Object?>> addStaff(Map<String, Object?> body) async {
    final http.Response r;
    try {
      r = await _http.post(Uri.parse('$baseUrl/sync/staff'), headers: _h, body: jsonEncode(body)).timeout(const Duration(seconds: 20));
    } catch (_) {
      throw HubError(503, 'offline', 'Adding a person needs internet on the main device. Billing keeps working offline; try again when it is back online.');
    }
    final j = r.body.isEmpty ? const <String, Object?>{} : jsonDecode(r.body) as Map<String, Object?>;
    if (r.statusCode != 201) {
      final m = j['message'];
      throw HubError(r.statusCode >= 500 ? 502 : r.statusCode, '${j['code'] ?? 'cloud_error'}', m is List ? m.join(', ') : '${m ?? 'The server refused it'}');
    }
    return j;
  }

  /// A console session (access + refresh token) for the owner / Restaurant Admin signed in on this hub.
  Future<Map<String, Object?>> consoleSession(String actorUserId) async {
    final http.Response r;
    try {
      // the cloud may be waking up (free hosting): up to a minute
      r = await _http.post(Uri.parse('$baseUrl/sync/console-session'), headers: _h, body: jsonEncode({'actorUserId': actorUserId})).timeout(const Duration(seconds: 75));
    } catch (_) {
      throw HubError(503, 'offline', 'The owner console needs internet on the main device.');
    }
    final Map<String, Object?> j;
    try {
      final d = r.body.isEmpty ? null : jsonDecode(r.body);
      j = d is Map<String, Object?> ? d : const {};
    } on FormatException {
      // e.g. the hosting's own "starting up" page
      throw HubError(503, 'cloud_starting', 'The server is starting up. Try again in a minute.');
    }
    if (r.statusCode != 200) throw HubError(r.statusCode >= 500 ? 502 : r.statusCode, '${j['code'] ?? 'cloud_error'}', '${j['message'] ?? 'The server refused it'}');
    return j;
  }

  /// The branch's orders / bills / payments the cloud stored after [after] (cursor from the previous page).
  Future<Map<String, Object?>> history(String? after) async {
    final q = after == null ? '' : '?after=${Uri.encodeQueryComponent(after)}';
    final r = await _http.get(Uri.parse('$baseUrl/sync/history$q'), headers: _h).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw http.ClientException('history failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, Object?>;
  }

  /// Tells the cloud which terminals are on this hub and who is signed in on each (shown in the console).
  Future<void> reportDevices(List<Map<String, Object?>> devices) async {
    final r = await _http.post(Uri.parse('$baseUrl/sync/devices'), headers: _h, body: jsonEncode({'devices': devices})).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw http.ClientException('device report failed: ${r.statusCode}');
  }

  /// Registers the hash of the one-time code this hub gave the terminal the owner chose as the new main device.
  Future<void> promotionCode(String requestId, String codeHash) async {
    final r = await _http.post(Uri.parse('$baseUrl/sync/promotion'), headers: _h, body: jsonEncode({'requestId': requestId, 'codeHash': codeHash})).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw http.ClientException('promotion failed: ${r.statusCode}');
  }

  Future<List<Map<String, Object?>>> push(List<Map<String, Object?>> events) async {
    final r = await _http
        .post(Uri.parse('$baseUrl/sync/push'), headers: _h, body: jsonEncode({'events': events}))
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw http.ClientException('push failed: ${r.statusCode} ${r.body}');
    return ((jsonDecode(r.body) as Map<String, Object?>)['results']! as List).cast<Map<String, Object?>>();
  }
}

class PushOutcome {
  const PushOutcome({this.sent = 0, this.accepted = 0, this.duplicate = 0, this.rejected = 0, this.error});
  final int sent, accepted, duplicate, rejected;
  final String? error;
  bool get ok => error == null;
}

/// Outbox push worker: batches of up to [batchSize] every [interval] while online; exponential backoff
/// (1 s, 2 s, 4 s … capped at [maxBackoff]) while the cloud is unreachable. "duplicate" counts as delivered —
/// the cloud already has it — so a batch replayed after a lost response is harmless (exactly-once storage).
class SyncWorker {
  SyncWorker(this.db, this.hub, this.cloud,
      {this.batchSize = 200, this.interval = const Duration(seconds: 5), this.maxBackoff = const Duration(minutes: 5), this.pullEvery = const Duration(seconds: 60)});

  final HubDatabase db;
  final HubService hub;
  final CloudClient cloud;
  final int batchSize;
  final Duration interval;
  final Duration maxBackoff;
  final Duration pullEvery;

  int consecutiveFailures = 0;
  Timer? _timer;
  DateTime? _lastPull;
  bool _running = false;

  Duration get currentDelay {
    if (consecutiveFailures == 0) return interval;
    final secs = min(pow(2, consecutiveFailures - 1).toInt(), maxBackoff.inSeconds);
    return Duration(seconds: secs);
  }

  Future<PushOutcome> pushOnce() async {
    final rows = await db.query("SELECT * FROM sync_outbox WHERE status = 'pending' ORDER BY seq LIMIT ?", [batchSize]);
    if (rows.isEmpty) return const PushOutcome();
    final events = rows
        .map((r) => {
              'eventId': r['event_id'], 'entity': r['entity'], 'entityId': r['entity_id'], 'op': r['op'],
              'payload': jsonDecode(r['payload']! as String), 'createdAt': r['created_at'],
            })
        .toList();
    List<Map<String, Object?>> results;
    try {
      results = await cloud.push(events);
    } catch (e) {
      consecutiveFailures++;
      await db.execute(
        "UPDATE sync_outbox SET attempts = attempts + 1, last_error = ? WHERE status = 'pending' AND seq <= ?",
        ['$e'.substring(0, min('$e'.length, 500)), rows.last['seq']],
      );
      return PushOutcome(sent: rows.length, error: '$e');
    }
    consecutiveFailures = 0;
    var acc = 0, dup = 0, rej = 0;
    await db.transaction(() async {
      for (final r in results) {
        switch (r['result']) {
          case 'accepted' || 'duplicate':
            r['result'] == 'accepted' ? acc++ : dup++;
            await db.execute("UPDATE sync_outbox SET status = 'pushed', pushed_at = ?, attempts = attempts + 1 WHERE event_id = ?", [nowIso(), r['eventId']]);
          default:
            rej++; // stored in the cloud's sync_conflicts; never retried
            await db.execute("UPDATE sync_outbox SET status = 'failed', last_error = ?, attempts = attempts + 1 WHERE event_id = ?", [r['reason'], r['eventId']]);
        }
      }
    });
    return PushOutcome(sent: rows.length, accepted: acc, duplicate: dup, rejected: rej);
  }

  /// Pulls config changes since the stored cursor and applies them (license token verified first).
  Future<void>? _pulling;
  Future<void> pullOnce() => _pulling ??= _pullConfig().whenComplete(() => _pulling = null);

  Future<void> _pullConfig() async {
    final since = await db.getMeta('config_cursor') ?? '0';
    final body = await cloud.pull(since);
    await hub.applyConfig(body);
    await _handlePromotion(body['promotion']);
    await db.setMeta('last_pull_at', nowIso());
    _lastPull = DateTime.now();
    hub.mediaFetcher ??= cloud.media;
    await prefetchMedia();
  }

  /// Brings in the branch's bill history from the cloud (bills another main device took), page by page.
  Future<int> pullHistory({int maxPages = 20}) async {
    var n = 0;
    for (var i = 0; i < maxPages; i++) {
      final page = await cloud.history(await db.getMeta('history_cursor'));
      n += await hub.applyHistory(((page['events'] as List?) ?? const []).cast<Map<String, Object?>>());
      if (page['cursor'] != null) await db.setMeta('history_cursor', '${page['cursor']}');
      if (page['more'] != true) break;
    }
    return n;
  }

  /// The console asked to make one of this hub's terminals the main device: give it a one-time code (the cloud keeps
  /// only its hash) once per request.
  Future<void> _handlePromotion(Object? p) async {
    if (p is! Map || p['requestId'] == null) return;
    final id = '${p['requestId']}';
    if (await db.getMeta('promotion_request') == id) return;
    final code = randomToken();
    await cloud.promotionCode(id, sha256Hex(code));
    await hub.offerPromotion(requestId: id, deviceId: '${p['lanDeviceId']}', code: code, cloudUrl: cloud.baseUrl, expiresAt: '${p['expiresAt']}');
    await db.setMeta('promotion_request', id);
  }

  /// Caches new menu photos right after a pull so the menu still has photos when the internet drops.
  Future<int> prefetchMedia({int max = 40}) async {
    var n = 0;
    for (final id in (await hub.missingMedia()).take(max)) {
      try {
        if (await hub.media(id) != null) n++;
      } catch (_) {
        break; // offline: try again after the next pull
      }
    }
    return n;
  }

  Future<void> tick() async {
    final out = await pushOnce();
    final due = _lastPull == null || DateTime.now().difference(_lastPull!) >= pullEvery || (out.ok && out.sent > 0);
    if (due) {
      try {
        await pullOnce();
        await pullHistory();
        await cloud.reportDevices(await hub.deviceReport());
      } catch (_) {
        // offline: keep working on the LAN; the next tick retries
      }
    }
  }

  void start() {
    if (_running) return;
    _running = true;
    void schedule() {
      _timer = Timer(currentDelay, () async {
        try {
          await tick();
        } finally {
          if (_running) schedule();
        }
      });
    }

    schedule();
  }

  void stop() {
    _running = false;
    _timer?.cancel();
  }
}
