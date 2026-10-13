import 'dart:async';

import 'package:rsaas_core/rsaas_core.dart';
import 'package:rsaas_pos/hub/hub_api.dart';

/// In-memory hub with the same rules the real hub enforces (reason required, occupied tables, idempotent payments),
/// using rsaas_core for totals so screens show real numbers.
class FakeHubApi extends HubApi {
  final events$ = StreamController<Json>.broadcast();
  final payCalls = <String>[]; // idempotency keys received
  int failNextPayments = 0;
  final _paid = <String, Json>{};

  final staffList = [
    {'id': 'u-cash', 'name': 'Ravi', 'roles': ['cashier'], 'pin': '1234'},
    {'id': 'u-own', 'name': 'Owner', 'roles': ['owner'], 'pin': '9999'},
    {'id': 'u-w1', 'name': 'Anita', 'roles': ['waiter'], 'pin': '5555'},
  ];
  final tables = [
    {'id': 't1', 'floor_id': 'f1', 'name': '1', 'seats': 4},
    {'id': 't2', 'floor_id': 'f1', 'name': '2', 'seats': 2},
  ];
  final items = [
    {'id': 'i1', 'category_id': 'c1', 'name': 'Butter Chicken', 'price_paise': 34000, 'rate_bp': 500, 'available': 1, 'is_veg': 0, 'plate_colors': {'base': '#D9622B', 'sauce': '#F2C27B', 'garnish': '#4F8A3B'}},
    {'id': 'i2', 'category_id': 'c1', 'name': 'Garlic Naan', 'price_paise': 6000, 'rate_bp': 500, 'available': 1, 'is_veg': 1, 'plate_colors': null},
  ];
  final orders = <String, Json>{};
  final bills$ = <String, Json>{};
  int _seq = 0, _inv = 0;
  String _id(String p) => '$p-${++_seq}';

  Json _orderView(String id) {
    final o = orders[id]!;
    final lines = (o['lines'] as List).cast<Json>();
    final t = computeBill([
      for (final l in lines) LineInput(pricePaise: l['price_snapshot_paise'] as int, qty: l['qty'] as int, taxRateBp: l['tax_rate_snapshot_bp'] as int, reversed: l['status'] == 'reversed'),
    ]);
    final bill = bills$.values.where((b) => b['order_id'] == id).firstOrNull;
    return {...o, 'table_name': tables.where((x) => x['id'] == o['table_id']).firstOrNull?['name'], 'totals': t.toJson(), 'bill': bill};
  }

  @override
  Future<Json> health() async => {'status': 'ok'};
  @override
  Future<List<Json>> staff() async => [for (final s in staffList) {'id': s['id'], 'name': s['name'], 'roles': s['roles']}];
  @override
  Future<Json> login(String userId, String pin) async {
    final u = staffList.firstWhere((s) => s['id'] == userId);
    if (u['pin'] != pin) throw HubApiException(401, 'invalid_pin', 'Wrong user or PIN');
    sessionToken = 'sess-$userId';
    final perms = switch ((u['roles'] as List).first) {
      'owner' => ['order.read', 'order.write', 'order.transfer', 'order.reverse', 'order.reverse.sent', 'discount.apply', 'payment.take', 'kds.read'],
      'cashier' => ['order.read', 'order.write', 'order.transfer', 'order.reverse', 'payment.take', 'kds.read'],
      _ => ['order.read', 'order.write', 'order.transfer', 'order.reverse', 'kds.read'],
    };
    return {'sessionToken': sessionToken, 'user': {'id': userId, 'name': u['name']}, 'permissions': perms};
  }

  @override
  Future<Json> state() async {
    final live = orders.values.where((o) => o['status'] == 'open' || o['status'] == 'billed').toList();
    return {
      'floors': [{'id': 'f1', 'name': 'Ground'}],
      'tables': [
        for (final t in tables)
          {...t, 'status': live.any((o) => o['table_id'] == t['id']) ? 'occupied' : 'free', 'orderId': live.where((o) => o['table_id'] == t['id']).firstOrNull?['id']},
      ],
      'openOrders': live,
      'kds': [],
    };
  }

  @override
  Future<Json> menu() async => {'categories': [{'id': 'c1', 'name': 'Mains'}], 'items': items};

  @override
  Future<Json> openOrder({required String type, String? tableId, String? waiterId}) async {
    if (tableId != null && orders.values.any((o) => o['table_id'] == tableId && (o['status'] == 'open' || o['status'] == 'billed'))) {
      throw HubApiException(409, 'table_occupied', 'Table already has an open order');
    }
    final id = _id('o');
    orders[id] = {'id': id, 'type': type, 'table_id': tableId, 'waiter_id': waiterId, 'status': 'open', 'version': 1, 'lines': <Json>[]};
    events$.add({'type': 'table.status_changed'});
    return _orderView(id);
  }

  @override
  Future<Json> order(String id) async => _orderView(id);

  @override
  Future<Json> addLines(String orderId, List<Json> lines) async {
    for (final l in lines) {
      final it = items.firstWhere((i) => i['id'] == l['menuItemId']);
      (orders[orderId]!['lines'] as List).add({
        'id': _id('l'), 'menu_item_id': it['id'], 'name_snapshot': it['name'], 'price_snapshot_paise': it['price_paise'],
        'tax_rate_snapshot_bp': it['rate_bp'], 'qty': l['qty'], 'status': 'pending', 'notes': null,
      });
    }
    return _orderView(orderId);
  }

  Json _line(String o, String l) => (orders[o]!['lines'] as List).cast<Json>().firstWhere((x) => x['id'] == l);

  @override
  Future<Json> updateLine(String orderId, String lineId, {int? qty, String? notes}) async {
    _line(orderId, lineId)['qty'] = qty ?? _line(orderId, lineId)['qty'];
    return _orderView(orderId);
  }

  @override
  Future<Json> sendKot(String orderId) async {
    for (final l in (orders[orderId]!['lines'] as List).cast<Json>().where((l) => l['status'] == 'pending')) {
      l['status'] = 'sent';
    }
    return {'kotNo': 1};
  }

  final reversals = <Json>[];
  @override
  Future<Json> reverseLine(String orderId, String lineId, {required String reason, String? approverUserId, String? approverPin}) async {
    if (reason.trim().length < 3) throw HubApiException(400, 'reason_required', 'A reason is required');
    final l = _line(orderId, lineId);
    reversals.add({'lineId': lineId, 'reason': reason, 'approver': approverUserId, 'pin': approverPin});
    l['status'] = 'reversed';
    l['reversal_reason'] = reason;
    return _orderView(orderId);
  }

  @override
  Future<Json> transfer(String orderId, String toTableId) async {
    if (orders.values.any((o) => o['table_id'] == toTableId && o['status'] == 'open')) throw HubApiException(409, 'table_occupied', 'Table is occupied');
    orders[orderId]!['table_id'] = toTableId;
    return _orderView(orderId);
  }

  @override
  Future<Json> bill(String orderId, {Json? discount, String? discountReason}) async {
    final o = orders[orderId]!;
    final t = computeBill([
      for (final l in (o['lines'] as List).cast<Json>())
        LineInput(pricePaise: l['price_snapshot_paise'] as int, qty: l['qty'] as int, taxRateBp: l['tax_rate_snapshot_bp'] as int, reversed: l['status'] == 'reversed'),
    ], discount: Discount.fromJson(discount?.cast<String, Object?>()));
    final id = _id('b');
    o['status'] = 'billed';
    return bills$[id] = {
      'id': id, 'order_id': orderId, 'invoice_no': formatInvoiceNo('BR01', '26-27', ++_inv), 'subtotal_paise': t.subtotalPaise, 'discount_paise': t.discountPaise,
      'cgst_paise': t.cgstPaise, 'sgst_paise': t.sgstPaise, 'tip_paise': 0, 'round_off_paise': t.roundOffPaise, 'total_paise': t.totalPaise, 'status': 'open',
      'created_at': '2026-10-12T10:00:00.000Z', 'discount': discount,
    };
  }

  @override
  Future<Json> pay(String billId, String idempotencyKey, {required String mode, int? amountPaise, int? tenderedPaise, String? reference}) async {
    payCalls.add(idempotencyKey);
    if (failNextPayments > 0) {
      failNextPayments--;
      throw HubApiException(0, 'hub_offline', 'Kitchen hub offline');
    }
    if (_paid.containsKey(idempotencyKey)) return {..._paid[idempotencyKey]!, 'replayed': true};
    final b = bills$[billId]!;
    final already = _paid.values.where((p) => p['billId'] == billId).fold<int>(0, (a, p) => a + (p['amountPaise'] as int));
    final s = applyPayments((b['total_paise'] as int) - already, [mode == 'cash' ? PaymentInput.cash(tenderedPaise!) : mode == 'upi' ? PaymentInput.upi(amountPaise!) : PaymentInput.card(amountPaise!)]);
    final r = {'billId': billId, 'mode': mode, 'amountPaise': s.applied.single.appliedPaise, 'changePaise': s.changePaise, 'billStatus': s.settled ? 'paid' : 'open'};
    if (s.settled) {
      b['status'] = 'paid';
      orders[b['order_id']]!['status'] = 'paid';
    }
    return _paid[idempotencyKey] = r;
  }

  Json? lastTip;
  @override
  Future<Json> tip(String billId, {required int amountPaise, String? waiterId}) async {
    lastTip = {'billId': billId, 'amountPaise': amountPaise, 'waiterId': waiterId};
    final b = bills$[billId]!;
    final before = (b['total_paise'] as int) - (b['tip_paise'] as int) - (b['round_off_paise'] as int);
    b['tip_paise'] = amountPaise;
    final pre = before + amountPaise;
    b['round_off_paise'] = roundOffToRupee(pre);
    b['total_paise'] = pre + (b['round_off_paise'] as int);
    return {'billId': billId, 'waiterId': waiterId, 'tipPaise': amountPaise};
  }

  @override
  Future<List<Json>> bills(DateTime day) async => bills$.values.toList();
  @override
  Future<Json> syncStatus() async => {'pending': 3, 'pushed': 10, 'failed': 0};
  @override
  Stream<Json> events() => events$.stream;
}
