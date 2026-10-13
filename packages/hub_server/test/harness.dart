import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart';
import 'package:rsaas_hub/rsaas_hub.dart';

/// Test fixture: a hub with an in-memory DB, a test Ed25519 license key, menu, tables and staff.
class Harness {
  Harness._(this.hub, this.server, this.base, this.deviceToken, this._sign, this.publicKeyB64, this._clock);

  final HubService hub;
  final HubServer server;
  final String base;
  final String deviceToken;
  final Future<String> Function(Map<String, Object?>) _sign;
  final String publicKeyB64;
  final _Clock _clock;
  DateTime get now => _clock.now;
  set now(DateTime t) => _clock.now = t;

  static const branchId = '01900000-0000-7000-8000-000000000b01';
  static const owner = '01900000-0000-7000-8000-0000000000a1';
  static const cashier = '01900000-0000-7000-8000-0000000000a2';
  static const waiter = '01900000-0000-7000-8000-0000000000a3';
  static const waiter2 = '01900000-0000-7000-8000-0000000000a4';
  static const chef = '01900000-0000-7000-8000-0000000000a5';
  static const discountCashier = '01900000-0000-7000-8000-0000000000a6';
  static const t1 = '01900000-0000-7000-8000-0000000000c1';
  static const t2 = '01900000-0000-7000-8000-0000000000c2';
  static const t3 = '01900000-0000-7000-8000-0000000000c3';
  static const butterChicken = '01900000-0000-7000-8000-0000000000d1';
  static const naan = '01900000-0000-7000-8000-0000000000d2';
  static const lassi = '01900000-0000-7000-8000-0000000000d3';
  static const pins = {owner: '9999', cashier: '1234', waiter: '5555', waiter2: '6666', chef: '7777', discountCashier: '4321'};

  static Future<Harness> start({String plan = 'professional', int expDays = 30, int nbfDays = -1}) async {
    final algo = Ed25519();
    final kp = await algo.newKeyPair();
    final pub = await kp.extractPublicKey();
    // SPKI DER for Ed25519 = fixed 12-byte prefix + 32-byte key (same format the cloud exports)
    final spki = base64.encode([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00, ...pub.bytes]);
    Future<String> sign(Map<String, Object?> payload) async {
      final body = base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
      final sig = await algo.sign(utf8.encode(body), keyPair: kp);
      return '$body.${base64Url.encode(sig.bytes).replaceAll('=', '')}';
    }

    final clock = _Clock();
    final hub = HubService(HubDatabase.memory(), HubConfig(branchId: branchId, branchCode: 'BR01', licensePublicKey: spki), clock: () => clock.now);
    final server = HubServer(hub, hubName: 'Test hub', certFingerprint: 'AA:BB');
    final s = await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    final token = await hub.registerSelf('Cashier PC', 'windows');
    final h = Harness._(hub, server, 'http://127.0.0.1:${s.port}/hub/v1', token, sign, spki, clock);
    await hub.applyConfig(await h.configPull(plan: plan, expDays: expDays, nbfDays: nbfDays));
    return h;
  }

  Future<String> license({String plan = 'professional', int expDays = 30, int nbfDays = -1, String tid = 'tenant-1'}) {
    final features = {
      'standard': ['tables', 'orders.dinein', 'orders.takeaway', 'menu', 'billing', 'offline.single'],
      'professional': ['tables', 'orders.dinein', 'orders.takeaway', 'menu', 'billing', 'offline.single', 'floors', 'multi_cashier', 'waiter_app', 'lan_hub'],
      'premium': ['tables', 'orders.dinein', 'orders.takeaway', 'menu', 'billing', 'offline.single', 'floors', 'multi_cashier', 'waiter_app', 'lan_hub',
        'franchise', 'roles.extended', 'kds', 'recipes', 'menu.approval', 'inventory', 'shifts'],
    }[plan]!;
    final t = now.millisecondsSinceEpoch ~/ 1000;
    return _sign({
      'v': 1, 'lic': 'lic-1', 'tid': tid, 'plan': plan, 'features': features, 'limits': {'devicesPerBranch': null},
      'nbf': t + nbfDays * 86400, 'exp': t + expDays * 86400, 'grace_days': 7, 'iat': t,
    });
  }

  Future<Map<String, Object?>> configPull({String plan = 'professional', int expDays = 30, int nbfDays = -1}) async => {
        'cursor': '42',
        'menuVersion': 3,
        'tenant': {'id': 'tenant-1', 'name': 'Demo Dhaba', 'gstin': '27AAAPA1234A1Z5', 'address': 'MG Road, Pune'},
        'licenseToken': await license(plan: plan, expDays: expDays, nbfDays: nbfDays),
        'branches': [{'id': branchId, 'code': 'BR01', 'name': 'Demo Dhaba — MG Road', 'gstin': '27AAAPA1234A1Z5', 'address': 'MG Road, Pune'}],
        'floors': [{'id': 'f1', 'name': 'Ground', 'sortOrder': 0, 'deleted': false}],
        'tables': [
          for (final (id, name) in [(t1, '1'), (t2, '2'), (t3, '3')]) {'id': id, 'floorId': 'f1', 'name': name, 'seats': 4, 'layoutX': 0, 'layoutY': 0, 'deleted': false},
        ],
        'taxRules': [
          {'id': 'tx5', 'name': 'GST 5%', 'rateBp': 500, 'deleted': false},
          {'id': 'tx12', 'name': 'GST 12%', 'rateBp': 1200, 'deleted': false},
        ],
        'categories': [{'id': 'c1', 'name': 'Mains', 'sortOrder': 0, 'deleted': false}],
        'items': [
          {'id': butterChicken, 'categoryId': 'c1', 'name': 'Butter Chicken', 'pricePaise': 34000, 'taxRuleId': 'tx5', 'available': true, 'isVeg': false, 'deleted': false},
          {'id': naan, 'categoryId': 'c1', 'name': 'Garlic Naan', 'pricePaise': 6000, 'taxRuleId': 'tx5', 'available': true, 'isVeg': true, 'deleted': false},
          {'id': lassi, 'categoryId': 'c1', 'name': 'Mango Lassi', 'pricePaise': 12000, 'taxRuleId': 'tx12', 'available': true, 'isVeg': true, 'deleted': false},
        ],
        'users': [
          _user(owner, 'Owner', 'owner'),
          _user(cashier, 'Ravi', 'cashier'),
          _user(waiter, 'Anita', 'waiter'),
          _user(waiter2, 'Sohan', 'waiter'),
          _user(chef, 'Chef', 'chef'),
          _user(discountCashier, 'Meera', 'cashier', extra: ['discount.apply']),
        ],
      };

  static Map<String, Object?> _user(String id, String name, String role, {List<String> extra = const []}) => {
        'id': id, 'name': name, 'status': 'active', 'pinHash': fastArgon2(pins[id]!),
        'roles': [{'role': role, 'extraPermissions': extra}],
      };

  /// Low-cost Argon2id PHC string so tests stay fast (production hashes use m=19456, t=2).
  static String fastArgon2(String secret) {
    final salt = Uint8List.fromList(List.generate(16, (i) => i * 7 % 256));
    final gen = Argon2BytesGenerator()
      ..init(Argon2Parameters(Argon2Parameters.ARGON2_id, salt, desiredKeyLength: 32, iterations: 1, memory: 256, lanes: 1, version: Argon2Parameters.ARGON2_VERSION_13));
    final out = gen.process(Uint8List.fromList(utf8.encode(secret)));
    String b(List<int> x) => base64.encode(x).replaceAll('=', '');
    return '\$argon2id\$v=19\$m=256,t=1,p=1\$${b(salt)}\$${b(out)}';
  }

  Map<String, String> headers({String? session, String? idem}) => {
        'content-type': 'application/json',
        'x-device-token': deviceToken,
        if (session != null) 'authorization': 'Bearer $session',
        if (idem != null) 'idempotency-key': idem,
      };

  Future<String> login(String userId) async {
    final r = await http.post(Uri.parse('$base/session/login'), headers: headers(), body: jsonEncode({'userId': userId, 'pin': pins[userId]}));
    if (r.statusCode != 200) throw StateError('login failed ${r.body}');
    return (jsonDecode(r.body) as Map)['sessionToken'] as String;
  }

  Future<Res> post(String path, {String? session, Object? body, String? idem}) async {
    final r = await http.post(Uri.parse('$base$path'), headers: headers(session: session, idem: idem), body: jsonEncode(body ?? {}));
    return Res(r.statusCode, r.body.isEmpty ? null : jsonDecode(r.body));
  }

  Future<Res> patch(String path, {String? session, Object? body}) async {
    final r = await http.patch(Uri.parse('$base$path'), headers: headers(session: session), body: jsonEncode(body ?? {}));
    return Res(r.statusCode, r.body.isEmpty ? null : jsonDecode(r.body));
  }

  Future<Res> put(String path, {String? session, Object? body}) async {
    final r = await http.put(Uri.parse('$base$path'), headers: headers(session: session), body: jsonEncode(body ?? {}));
    return Res(r.statusCode, r.body.isEmpty ? null : jsonDecode(r.body));
  }

  Future<Res> get(String path, {String? session}) async {
    final r = await http.get(Uri.parse('$base$path'), headers: headers(session: session));
    return Res(r.statusCode, r.body.isEmpty ? null : jsonDecode(r.body));
  }

  Future<void> close() async {
    await server.stop();
    await hub.close();
    await hub.db.close();
  }
}

class Res {
  Res(this.status, this.body);
  final int status;
  final Object? body;
  Map<String, Object?> get json => body! as Map<String, Object?>;
  String? get code => (body is Map) ? (body! as Map)['code'] as String? : null;
  @override
  String toString() => 'Res($status, $body)';
}

/// In-memory stand-in for the cloud's /sync endpoints with the same dedupe semantics (event_id unique).
class FakeCloud {
  final stored = <String, Map<String, Object?>>{};
  int received = 0;
  bool dropNextResponse = false;
  bool offline = false;
  String? rejectEntity;
  Map<String, Object?>? pullBody;
  String? lastSince;

  http.Client client() => MockClient((req) async {
        if (offline) throw const SocketException('network unreachable');
        if (req.url.path.endsWith('/sync/pull')) {
          lastSince = req.url.queryParameters['since'];
          return http.Response.bytes(utf8.encode(jsonEncode(pullBody ?? {})), 200, headers: {'content-type': 'application/json; charset=utf-8'});
        }
        final events = ((jsonDecode(req.body) as Map)['events'] as List).cast<Map<String, Object?>>();
        final results = <Map<String, Object?>>[];
        for (final e in events) {
          received++;
          final id = e['eventId']! as String;
          if (e['entity'] == rejectEntity) {
            results.add({'eventId': id, 'result': 'rejected', 'reason': 'entity not accepted'});
          } else if (stored.containsKey(id)) {
            results.add({'eventId': id, 'result': 'duplicate'});
          } else {
            stored[id] = e;
            results.add({'eventId': id, 'result': 'accepted'});
          }
        }
        if (dropNextResponse) {
          dropNextResponse = false;
          throw http.ClientException('connection reset after the cloud committed the batch');
        }
        return http.Response.bytes(utf8.encode(jsonEncode({'results': results})), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      });
}

class _Clock {
  DateTime now = DateTime.utc(2026, 10, 12, 8); // 13:30 IST, FY 26-27
}
