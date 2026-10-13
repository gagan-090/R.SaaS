import 'dart:async';
import 'dart:typed_data';

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
    {'id': 'u-chef', 'name': 'Kunal', 'roles': ['chef'], 'pin': '7777'},
    {'id': 'u-it', 'name': 'Imran', 'roles': ['it_admin'], 'pin': '3333'},
    {'id': 'u-aud', 'name': 'Asha', 'roles': ['auditor'], 'pin': '2222'},
  ];
  final tables = [
    {'id': 't1', 'floor_id': 'f1', 'name': '1', 'seats': 4},
    {'id': 't2', 'floor_id': 'f1', 'name': '2', 'seats': 2},
  ];
  final items = [
    {'id': 'i1', 'category_id': 'c1', 'name': 'Butter Chicken', 'price_paise': 34000, 'rate_bp': 500, 'available': 1, 'is_veg': 0, 'image_id': 'img-bc', 'plate_colors': {'base': '#D9622B', 'sauce': '#F2C27B', 'garnish': '#4F8A3B'}},
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
    return {
      ...o, 'table_name': tables.where((x) => x['id'] == o['table_id']).firstOrNull?['name'], 'totals': t.toJson(), 'bill': bill,
      'tickets': [for (final k in tickets.where((k) => k['orderId'] == id)) {'id': k['id'], 'kot_no': k['kotNo'], 'status': k['status']}],
    };
  }

  @override
  Future<Json> health() async => {'status': 'ok'};
  @override
  Future<List<Json>> staff() async => [for (final s in staffList) {'id': s['id'], 'name': s['name'], 'roles': s['roles'], 'hasPin': s['pin'] != null}];
  @override
  Future<Json> login(String userId, String pin) async {
    final u = staffList.firstWhere((s) => s['id'] == userId);
    if (u['pin'] != pin) throw HubApiException(401, 'invalid_pin', 'Wrong user or PIN');
    sessionToken = 'sess-$userId';
    // same grants as packages/hub_server/lib/src/permissions.dart
    final perms = switch ((u['roles'] as List).first) {
      'owner' => ['floor.read', 'menu.read', 'order.read', 'order.write', 'order.transfer', 'order.reverse', 'order.reverse.sent', 'discount.apply',
          'payment.take', 'bill.adjust', 'kds.read', 'device.manage', 'clock', 'reports.read', 'reports.own'],
      'cashier' => ['floor.read', 'menu.read', 'order.read', 'order.write', 'order.transfer', 'order.reverse', 'payment.take', 'kds.read', 'clock', 'reports.own'],
      'waiter' => ['floor.read', 'menu.read', 'order.read', 'order.write', 'order.transfer', 'order.reverse', 'kds.read', 'clock', 'reports.own'],
      'chef' => ['menu.read', 'kds.read', 'kds.update', 'clock'],
      'it_admin' => ['floor.read', 'menu.read', 'device.manage', 'clock', 'reports.read'],
      _ => ['floor.read', 'menu.read', 'order.read', 'kds.read', 'reports.read'], // auditor
    };
    _perms = perms.toSet();
    return {'sessionToken': sessionToken, 'user': {'id': userId, 'name': u['name'], 'roles': u['roles']}, 'permissions': perms};
  }

  @override
  Future<Json> state() async {
    final live = orders.values.where((o) => o['status'] == 'open' || o['status'] == 'billed').toList();
    return {
      'floors': [{'id': 'f1', 'name': 'Ground'}],
      'tables': [
        for (final t in tables)
          () {
            final o = live.where((o) => o['table_id'] == t['id']).firstOrNull;
            return {
              ...t,
              'status': o == null ? 'free' : (o['status'] == 'billed' ? 'bill_printed' : 'occupied'),
              'orderId': o?['id'],
              'totalPaise': o == null ? null : (_orderView(o['id'] as String)['totals'] as Json)['totalPaise'],
              'openedAt': o?['opened_at'],
              'waiterName': staffList.where((u) => u['id'] == o?['waiter_id']).firstOrNull?['name'],
            };
          }(),
      ],
      'openOrders': [for (final o in live) {...o, 'total_paise': (_orderView(o['id'] as String)['totals'] as Json)['totalPaise'], 'item_count': (o['lines'] as List).length}],
      'kds': tickets.where((k) => k['status'] != 'served').toList(),
    };
  }

  @override
  Future<Json> menu() async => {'categories': [{'id': 'c1', 'name': 'Mains'}], 'items': items};

  @override
  Future<Json> branch() async => {'tenant': {'name': 'Demo Dhaba', 'branding': ?branding}, 'branch': {'name': 'Demo Dhaba — MG Road', 'code': 'BR01'}};
  Json? branding; // plan feature "branding", as pulled from the cloud

  final mediaRequests = <String>[];
  @override
  Future<Uint8List?> media(String id) async {
    mediaRequests.add(id);
    return null; // no photo bytes in tests: the plate illustration shows
  }

  @override
  Future<Json> openOrder({required String type, String? tableId, String? waiterId}) async {
    if (tableId != null && orders.values.any((o) => o['table_id'] == tableId && (o['status'] == 'open' || o['status'] == 'billed'))) {
      throw HubApiException(409, 'table_occupied', 'Table already has an open order');
    }
    final id = _id('o');
    orders[id] = {'id': id, 'type': type, 'table_id': tableId, 'waiter_id': waiterId, 'status': 'open', 'version': 1, 'lines': <Json>[], 'opened_at': DateTime.now().toUtc().toIso8601String()};
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
    if (notes != null) _line(orderId, lineId)['notes'] = notes;
    return _orderView(orderId);
  }

  final tickets = <Json>[];
  @override
  Future<Json> sendKot(String orderId) async {
    final sent = <Json>[];
    for (final l in (orders[orderId]!['lines'] as List).cast<Json>().where((l) => l['status'] == 'pending')) {
      l['status'] = 'sent';
      sent.add(l);
    }
    final o = orders[orderId]!;
    final k = {
      'id': _id('k'), 'kotNo': tickets.length + 1, 'status': 'new', 'createdAt': DateTime.now().toUtc().toIso8601String(), 'orderId': orderId,
      'where': o['table_id'] == null ? 'TAKEAWAY' : 'Table ${tables.firstWhere((t) => t['id'] == o['table_id'])['name']}',
      'waiter': staffList.where((u) => u['id'] == o['waiter_id']).firstOrNull?['name'],
      'lines': [for (final l in sent) {'id': l['id'], 'name': l['name_snapshot'], 'qty': l['qty'], 'notes': l['notes'], 'reversed': false}],
    };
    tickets.add(k);
    events$.add({'type': 'kds.ticket_created', 'data': {'orderId': orderId}});
    return {'ticketId': k['id'], 'kotNo': k['kotNo']};
  }

  int kdsLoads = 0;
  @override
  Future<List<Json>> kdsTickets() async {
    kdsLoads++;
    return tickets.where((k) => k['status'] != 'served').toList();
  }

  @override
  Future<Json> setTicketStatus(String ticketId, String status) async {
    if (!_perms.contains('kds.update')) throw HubApiException(403, 'missing_permission', 'Missing permission: kds.update');
    final k = tickets.firstWhere((k) => k['id'] == ticketId);
    k['status'] = status;
    events$.add({'type': 'kds.ticket_status', 'data': {'orderId': k['orderId'], 'status': status}});
    return k;
  }

  Set<String> _perms = {};

  @override
  Future<List<Json>> tips() async => [
        if (lastTip != null) {'waiter_id': lastTip!['waiterId'], 'waiter_name': 'Anita', 'tip_paise': lastTip!['amountPaise'], 'bills': 1},
      ];

  /// Printer stand-in: null = none configured (the hub answers with a PDF / no_printer).
  Json printerSettings = {};
  final printed = <String>[];
  @override
  Future<Json> printBill(String billId, {bool ifPrinter = false}) async {
    if (printerSettings['bill'] == null) return ifPrinter ? {'status': 'no_printer'} : {'status': 'pdf', 'error': 'no_printer'};
    printed.add(billId);
    return {'status': 'printed', 'copyNo': printed.where((b) => b == billId).length};
  }

  @override
  Future<Json> reprintKot(String ticketId) async => {'status': 'printed', 'copyNo': 2};
  @override
  Future<Json> printers() async => printerSettings;
  @override
  Future<Json> savePrinters(Json settings) async {
    if (!_perms.contains('device.manage')) throw HubApiException(403, 'missing_permission', 'Missing permission: device.manage');
    return printerSettings = {for (final e in settings.entries) if (e.value != null) e.key: e.value};
  }

  final testPrints = <String>[];
  @override
  Future<Json> testPrint(String target) async {
    testPrints.add(target);
    return {'status': 'printed', 'target': target};
  }

  final adjustments = <Json>[];
  @override
  Future<Json> adjust(String billId, {required int amountPaise, required String reason, String? approverUserId, String? approverPin}) async {
    final a = {'billId': billId, 'amountPaise': amountPaise, 'reason': reason, 'approver': approverUserId, 'pin': approverPin};
    adjustments.add(a);
    return a;
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
      events$.add({'type': 'bill.paid', 'data': {'billId': billId, 'orderId': b['order_id']}});
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
