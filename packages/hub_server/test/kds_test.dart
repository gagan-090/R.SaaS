import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;
  late String cashier, waiter, chef;
  setUp(() async {
    h = await Harness.start(plan: 'premium');
    cashier = await h.login(Harness.cashier);
    waiter = await h.login(Harness.waiter);
    chef = await h.login(Harness.chef);
  });
  tearDown(() => h.close());

  Future<(String, String)> kot() async {
    final o = (await h.post('/orders', session: waiter, body: {'type': 'dine_in', 'tableId': Harness.t2, 'waiterId': Harness.waiter})).json;
    final id = o['id']! as String;
    await h.post('/orders/$id/lines', session: waiter, body: {
      'lines': [{'menuItemId': Harness.butterChicken, 'qty': 1, 'notes': 'mild'}, {'menuItemId': Harness.naan, 'qty': 2}],
    });
    final k = await h.post('/orders/$id/kot', session: waiter);
    expect(k.status, 201, reason: '$k');
    return (id, k.json['ticketId']! as String);
  }

  test('chef sees the queue with table, waiter and notes, and moves a ticket new → preparing → ready → served', () async {
    final (orderId, ticketId) = await kot();
    final q = (await h.get('/kds/tickets', session: chef)).body! as List;
    expect(q, hasLength(1));
    final t = q.single as Map;
    expect(t['where'], 'Table 2');
    expect(t['waiter'], 'Anita');
    expect(t['status'], 'new');
    expect((t['lines'] as List).first, containsPair('notes', 'mild'));

    expect((await h.post('/kds/tickets/$ticketId/status', session: chef, body: {'status': 'served'})).code, 'bad_transition');
    for (final s in ['preparing', 'ready']) {
      final r = await h.post('/kds/tickets/$ticketId/status', session: chef, body: {'status': s});
      expect(r.status, 200, reason: '$r');
      expect(r.json['status'], s);
    }
    // the waiter sees "ready" on the order
    final o = (await h.get('/orders/$orderId', session: waiter)).json;
    expect(((o['tickets']! as List).single as Map)['status'], 'ready');
    await h.post('/kds/tickets/$ticketId/status', session: chef, body: {'status': 'served'});
    expect((await h.get('/kds/tickets', session: chef)).body, isEmpty);
    final outbox = await h.hub.db.query("SELECT op FROM sync_outbox WHERE entity = 'kitchen_ticket' ORDER BY seq");
    expect(outbox.map((r) => r['op']), ['create', 'update', 'update', 'update']);
  });

  test('a reversed line is flagged on the ticket; waiters and cashiers cannot change ticket status', () async {
    final (orderId, ticketId) = await kot();
    final order = (await h.get('/orders/$orderId', session: cashier)).json;
    final naan = ((order['lines']! as List).cast<Map<String, dynamic>>()).firstWhere((l) => l['name_snapshot'] == 'Garlic Naan');
    final owner = await h.login(Harness.owner);
    final rev = await h.post('/orders/$orderId/lines/${naan['id']}/reverse', session: owner, body: {'reason': 'guest changed mind'});
    expect(rev.status, 200, reason: '$rev');
    final t = ((await h.get('/kds/tickets', session: chef)).body! as List).single as Map;
    expect((t['lines'] as List).cast<Map<String, dynamic>>().firstWhere((l) => l['name'] == 'Garlic Naan')['reversed'], isTrue);
    expect((await h.post('/kds/tickets/$ticketId/status', session: waiter, body: {'status': 'ready'})).status, 403);
    expect((await h.post('/kds/tickets/$ticketId/status', session: cashier, body: {'status': 'ready'})).status, 403);
  });

  test('KDS needs the kds feature (Premium); a waiter only sees their own tips', () async {
    final pro = await Harness.start();
    final c = await pro.login(Harness.chef);
    final o = (await pro.post('/orders', session: await pro.login(Harness.cashier), body: {'type': 'takeaway'})).json;
    final cs = await pro.login(Harness.cashier);
    await pro.post('/orders/${o['id']}/lines', session: cs, body: {'lines': [{'menuItemId': Harness.naan, 'qty': 1}]});
    final k = (await pro.post('/orders/${o['id']}/kot', session: cs)).json;
    expect((await pro.post('/kds/tickets/${k['ticketId']}/status', session: c, body: {'status': 'ready'})).code, 'feature_not_in_plan');
    await pro.close();

    final (orderId, _) = await kot();
    final bill = (await h.post('/orders/$orderId/bill', session: cashier)).json;
    await h.post('/bills/${bill['id']}/tip', session: cashier, body: {'amountPaise': 5000});
    final w2 = await h.login(Harness.waiter2);
    expect((await h.get('/reports/tips', session: w2)).body, isEmpty);
    expect((await h.get('/reports/tips', session: waiter)).body, [{'waiter_id': Harness.waiter, 'waiter_name': 'Anita', 'tip_paise': 5000, 'bills': 1}]);
    expect((await h.get('/reports/tips', session: chef)).status, 403);
  });
}
