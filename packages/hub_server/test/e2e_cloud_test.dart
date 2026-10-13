@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:rsaas_hub/rsaas_hub.dart';
import 'package:test/test.dart';

/// End to end against a RUNNING cloud API — exactly what the POS app does in Hub mode on a phone:
/// owner signs in → register-hub → pull the restaurant → every role works on the hub → events sync back.
///
///   E2E_API_URL=http://192.168.1.107:3000/api/v1 E2E_OWNER_EMAIL=owner@demo-dhaba.example E2E_OWNER_PASSWORD=… \
///     dart test test/e2e_cloud_test.dart
///
/// Needs the demo seed (`pnpm --filter @rsaas/api db:seed`: one user per role, all PIN 1234, Premium plan).
void main() {
  final env = Platform.environment;
  final api = env['E2E_API_URL'];
  final skip = api == null || env['E2E_OWNER_EMAIL'] == null || env['E2E_OWNER_PASSWORD'] == null
      ? 'set E2E_API_URL, E2E_OWNER_EMAIL and E2E_OWNER_PASSWORD to run against a live API'
      : false;

  test('hub on the live cloud: every role, then sync back', () async {
    Future<Map<String, dynamic>> cloud(String method, String path, {Object? body, String? bearer, String? device}) async {
      final req = http.Request(method, Uri.parse('$api$path'))
        ..headers.addAll({'content-type': 'application/json', if (bearer != null) 'authorization': 'Bearer $bearer', if (device != null) 'x-device-token': device});
      if (body != null) req.body = jsonEncode(body);
      final res = await http.Response.fromStream(await req.send());
      expect(res.statusCode, lessThan(300), reason: '$method $path → ${res.statusCode} ${res.body}');
      return jsonDecode(res.body) as Map<String, dynamic>;
    }

    // 1. owner signs in on the phone and registers it as the branch hub
    final login = await cloud('POST', '/auth/login', body: {'email': env['E2E_OWNER_EMAIL'], 'password': env['E2E_OWNER_PASSWORD']});
    expect(login['status'], 'ok', reason: 'tenant owners sign in without MFA enrolment');
    final reg = await cloud('POST', '/devices/register-hub', body: {'name': 'E2E phone hub', 'platform': 'android'}, bearer: login['accessToken'] as String);

    // 2. start the hub exactly like apps/pos_app/lib/hub/hub_mode_io.dart and pull the restaurant
    final db = HubDatabase.memory();
    final hub = HubService(db, HubConfig(branchId: reg['branchId'] as String, branchCode: reg['branchCode'] as String, licensePublicKey: reg['licensePublicKey'] as String));
    final worker = SyncWorker(db, hub, CloudClient(api!, reg['deviceToken'] as String));
    await worker.pullOnce();
    final lic = await hub.license();
    expect(lic.state, LicenseState.active, reason: 'license token from the cloud verifies offline on the hub');
    expect(lic.features, containsAll(['kds', 'lan_hub', 'roles.extended']), reason: 'demo seed is Premium');

    final server = HubServer(hub, hubName: 'e2e');
    final s = await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    addTearDown(() async {
      await server.stop();
      await hub.close();
      await db.close();
    });
    final base = 'http://127.0.0.1:${s.port}/hub/v1';
    final deviceToken = await hub.registerSelf('This hub', 'android');

    Future<(int, dynamic)> call(String method, String path, {String? session, Object? body, String? idem}) async {
      final req = http.Request(method, Uri.parse('$base$path'))
        ..headers.addAll({
          'content-type': 'application/json', 'x-device-token': deviceToken,
          if (session != null) 'authorization': 'Bearer $session', if (idem != null) 'idempotency-key': idem,
        });
      if (body != null) req.body = jsonEncode(body);
      final res = await http.Response.fromStream(await req.send());
      final isJson = (res.headers['content-type'] ?? '').contains('json');
      return (res.statusCode, isJson && res.body.isNotEmpty ? jsonDecode(res.body) : res.bodyBytes.length);
    }

    // 3. staff from the cloud: one per role, PIN 1234
    final (_, staffBody) = await call('GET', '/staff');
    final staff = (staffBody as List).cast<Map<String, dynamic>>();
    String idOf(String role) => staff.firstWhere((u) => (u['roles'] as List).contains(role), orElse: () => fail('no $role in the pulled staff'))['id'] as String;
    final sessions = <String, String>{};
    for (final role in ['owner', 'cashier', 'waiter', 'chef', 'it_admin', 'auditor']) {
      final (st, b) = await call('POST', '/session/login', body: {'userId': idOf(role), 'pin': '1234'});
      expect(st, 200, reason: '$role PIN login: $b');
      sessions[role] = (b as Map)['sessionToken'] as String;
    }
    final (_, state) = await call('GET', '/state');
    final tables = ((state as Map)['tables'] as List).cast<Map<String, dynamic>>();
    final freeTables = tables.where((t) => t['status'] == 'free').map((t) => t['id'] as String).toList();
    expect(freeTables.length, greaterThanOrEqualTo(2));
    final (_, menu) = await call('GET', '/menu');
    final items = ((menu as Map)['items'] as List).cast<Map<String, dynamic>>();
    String item(String name) => items.firstWhere((i) => i['name'] == name)['id'] as String;

    // waiter: opens a table as themselves, adds dishes with a note, sends KOT; cannot bill
    final (st1, order) = await call('POST', '/orders', session: sessions['waiter'], body: {'type': 'dine_in', 'tableId': freeTables[0], 'waiterId': idOf('waiter')});
    expect(st1, 201, reason: '$order');
    final orderId = (order as Map)['id'] as String;
    final (st2, _) = await call('POST', '/orders/$orderId/lines', session: sessions['waiter'], body: {
      'lines': [{'menuItemId': item('Butter Chicken'), 'qty': 1, 'notes': 'less spicy'}, {'menuItemId': item('Garlic Naan'), 'qty': 2}, {'menuItemId': item('Mango Lassi'), 'qty': 1}],
    });
    expect(st2, 201);
    final (st3, kot) = await call('POST', '/orders/$orderId/kot', session: sessions['waiter']);
    expect(st3, 201, reason: '$kot');
    expect((await call('POST', '/orders/$orderId/bill', session: sessions['waiter'])).$1, 403, reason: 'waiters cannot bill');

    // chef: sees the ticket with the note and moves it to ready; cannot touch orders
    final (_, q) = await call('GET', '/kds/tickets', session: sessions['chef']);
    final ticket = (q as List).cast<Map<String, dynamic>>().firstWhere((t) => t['orderId'] == orderId);
    expect((ticket['lines'] as List).cast<Map<String, dynamic>>().any((l) => l['notes'] == 'less spicy'), isTrue);
    for (final next in ['preparing', 'ready']) {
      final (st, r) = await call('POST', '/kds/tickets/${ticket['id']}/status', session: sessions['chef'], body: {'status': next});
      expect(st, 200, reason: 'chef → $next: $r');
    }
    expect((await call('POST', '/orders', session: sessions['chef'], body: {'type': 'takeaway'})).$1, 403);
    final (_, seen) = await call('GET', '/orders/$orderId', session: sessions['waiter']);
    expect((((seen as Map)['tickets'] as List).single as Map)['status'], 'ready', reason: 'waiter sees READY');

    // cashier: bills, tip to the waiter, split UPI + cash with an idempotent retry
    final (st4, bill) = await call('POST', '/orders/$orderId/bill', session: sessions['cashier']);
    expect(st4, 201, reason: '$bill');
    final billId = (bill as Map)['id'] as String;
    expect((await call('POST', '/bills/$billId/tip', session: sessions['cashier'], body: {'amountPaise': 2000})).$1, 200);
    final (_, b2) = await call('GET', '/orders/$orderId', session: sessions['cashier']);
    final total = (((b2 as Map)['bill'] as Map)['total_paise']) as int;
    final (st5, p1) = await call('POST', '/bills/$billId/payments', session: sessions['cashier'], idem: 'e2e-upi-${DateTime.now().microsecondsSinceEpoch}', body: {'mode': 'upi', 'amountPaise': 30000});
    expect(st5, 201, reason: '$p1');
    final cashKey = 'e2e-cash-${DateTime.now().microsecondsSinceEpoch}';
    final (_, p2) = await call('POST', '/bills/$billId/payments', session: sessions['cashier'], idem: cashKey, body: {'mode': 'cash', 'tenderedPaise': 200000});
    final (st6, p2again) = await call('POST', '/bills/$billId/payments', session: sessions['cashier'], idem: cashKey, body: {'mode': 'cash', 'tenderedPaise': 200000});
    expect(st6, 200);
    expect((p2again as Map)['paymentId'], (p2 as Map)['paymentId'], reason: 'retry with the same key is not a second charge');
    expect(p2['billStatus'], 'paid');
    expect(p2['changePaise'], 200000 - (total - 30000));
    final (st7, pdf) = await call('POST', '/bills/$billId/print', session: sessions['cashier']);
    expect(st7, 200);
    expect(pdf, isA<int>(), reason: 'no printer configured → PDF bytes');

    // IT admin: printer settings yes, orders no
    expect((await call('PUT', '/printers', session: sessions['it_admin'], body: {'bill': {'host': '127.0.0.1', 'port': 1}})).$1, 200);
    expect((await call('GET', '/orders/$orderId', session: sessions['it_admin'])).$1, 403);
    expect((await call('PUT', '/printers', session: sessions['cashier'], body: {'bill': null})).$1, 403);

    // owner: corrects the paid bill (no PIN needed for an owner), sees all tips
    final (st8, adj) = await call('POST', '/bills/$billId/adjustments', session: sessions['owner'], body: {'amountPaise': -1000, 'reason': 'naan was cold'});
    expect(st8, 201, reason: '$adj');
    final (_, tips) = await call('GET', '/reports/tips', session: sessions['owner']);
    expect((tips as List).cast<Map<String, dynamic>>().any((t) => t['waiter_id'] == idOf('waiter')), isTrue);

    // auditor: reads everything, changes nothing
    expect((await call('GET', '/orders/$orderId', session: sessions['auditor'])).$1, 200);
    expect((await call('GET', '/bills', session: sessions['auditor'])).$1, 200);
    expect((await call('POST', '/orders', session: sessions['auditor'], body: {'type': 'takeaway'})).$1, 403);
    expect((await call('POST', '/bills/$billId/adjustments', session: sessions['auditor'], body: {'amountPaise': -100, 'reason': 'test'})).$1, 403);

    // cashier takeaway, start to finish
    final (_, tk) = await call('POST', '/orders', session: sessions['cashier'], body: {'type': 'takeaway'});
    final tkId = (tk as Map)['id'] as String;
    await call('POST', '/orders/$tkId/lines', session: sessions['cashier'], body: {'lines': [{'menuItemId': item('Masala Chaas'), 'qty': 2}]});
    final (_, tkBill) = await call('POST', '/orders/$tkId/bill', session: sessions['cashier']);
    final (_, tkPay) = await call('POST', '/bills/${(tkBill as Map)['id']}/payments', session: sessions['cashier'], idem: 'e2e-card-${DateTime.now().microsecondsSinceEpoch}', body: {'mode': 'card', 'amountPaise': tkBill['total_paise']});
    expect((tkPay as Map)['billStatus'], 'paid');

    // 4. everything syncs to the cloud, nothing rejected
    var pushed = 0;
    for (var i = 0; i < 10; i++) {
      final o = await worker.pushOnce();
      expect(o.ok, isTrue, reason: o.error);
      expect(o.rejected, 0);
      pushed += o.accepted + o.duplicate;
      if (o.sent == 0) break;
    }
    final local = await hub.syncStatus();
    expect(local['pending'], 0);
    expect(local['failed'], 0);
    final remote = await cloud('GET', '/sync/status', device: reg['deviceToken'] as String);
    // ignore: avoid_print
    print('e2e: pushed $pushed events; cloud sync status: $remote');
    expect(pushed, greaterThan(20));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
