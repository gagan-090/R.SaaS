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
  Future<void> pullOnce() async {
    final since = await db.getMeta('config_cursor') ?? '0';
    final body = await cloud.pull(since);
    await hub.applyConfig(body);
    await db.setMeta('last_pull_at', nowIso());
    _lastPull = DateTime.now();
    hub.mediaFetcher ??= cloud.media;
    await prefetchMedia();
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
