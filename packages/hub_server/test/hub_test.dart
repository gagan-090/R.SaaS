import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:rsaas_hub/rsaas_hub.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'harness.dart';

void main() {
  late Harness h;
  late String cashier;
  late String owner;
  setUp(() async {
    h = await Harness.start();
    cashier = await h.login(Harness.cashier);
    owner = await h.login(Harness.owner);
  });
  tearDown(() => h.close());

  Future<String> openDineIn(String table, {String? waiterId, String? session}) async {
    final r = await h.post('/orders', session: session ?? cashier, body: {'type': 'dine_in', 'tableId': table, 'waiterId': waiterId ?? Harness.waiter});
    expect(r.status, 201, reason: '$r');
    return r.json['id']! as String;
  }

  Future<Map<String, Object?>> add(String orderId, List<Map<String, Object?>> lines) async {
    final r = await h.post('/orders/$orderId/lines', session: cashier, body: {'lines': lines});
    expect(r.status, 201, reason: '$r');
    return r.json;
  }

  group('session & pairing', () {
    test('staff PIN login; wrong PIN rejected; staff routes need a session', () async {
      final bad = await h.post('/session/login', body: {'userId': Harness.cashier, 'pin': '0000'});
      expect(bad.status, 401);
      expect((await h.post('/orders', body: {'type': 'takeaway'})).code, 'staff_login_required');
      expect((await h.get('/state')).status, 200);
    });

    test('pairing code is one-time and issues a branch-bound device token', () async {
      final info = await h.get('/pairing/info');
      expect(info.json['certFingerprint'], 'AA:BB');
      expect(info.json.containsKey('code'), isFalse);
      final code = await h.hub.createPairingCode();
      final c1 = await h.post('/pairing/claim', body: {'code': code, 'deviceName': 'Waiter phone', 'platform': 'android'});
      expect(c1.status, 201, reason: '$c1');
      expect(c1.json['branchId'], Harness.branchId);
      expect(await h.hub.authenticateDevice(c1.json['deviceToken']! as String), c1.json['deviceId']);
      expect((await h.post('/pairing/claim', body: {'code': code, 'deviceName': 'x', 'platform': 'android'})).code, 'invalid_pairing_code');
      // expired codes fail
      final old = await h.hub.createPairingCode();
      h.now = h.now.add(const Duration(minutes: 11));
      expect((await h.post('/pairing/claim', body: {'code': old, 'deviceName': 'x', 'platform': 'android'})).status, 401);
    });

    test('Standard plan cannot pair extra devices (lan_hub is Professional)', () async {
      await h.hub.applyConfig(await h.configPull(plan: 'standard'));
      final code = await h.hub.createPairingCode();
      expect((await h.post('/pairing/claim', body: {'code': code, 'deviceName': 'x', 'platform': 'android'})).code, 'feature_not_in_plan');
    });

    test('staff list and menu for the POS screens never expose PIN hashes', () async {
      final staff = (await h.get('/staff')).body! as List;
      expect(staff.map((s) => (s as Map)['name']), containsAll(['Ravi', 'Anita', 'Owner']));
      expect(jsonEncode(staff), isNot(contains('argon2')));
      final menu = (await h.get('/menu')).json;
      expect((menu['items']! as List).firstWhere((i) => (i as Map)['id'] == Harness.lassi), containsPair('rate_bp', 1200));
      expect(((await h.get('/branch')).json['branch']! as Map)['code'], 'BR01');
    });

    test('Argon2id PIN hashes from the cloud (node argon2) verify on the hub', () {
      const nodeHash = r'$argon2id$v=19$m=19456,p=1,t=2$Nyg+d4QuwlMXcFGftzjXKg$glolkwTphcD7kkBhYXA+CaBulAuakkaoTSspW3ZvHQ4';
      expect(verifyArgon2(nodeHash, '1234'), isTrue);
      expect(verifyArgon2(nodeHash, '1235'), isFalse);
    });
  });

  group('offline license (AC-02 on the hub)', () {
    test('tampered token is refused and never saved', () async {
      final good = await h.license();
      final parts = good.split('.');
      final p = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0])))) as Map<String, Object?>;
      p['features'] = [...(p['features']! as List), 'kds', 'franchise'];
      final forged = '${base64Url.encode(utf8.encode(jsonEncode(p))).replaceAll('=', '')}.${parts[1]}';
      await expectLater(h.hub.setLicenseToken(forged), throwsA(isA<HubError>().having((e) => e.code, 'code', 'license_invalid')));
      final pull = await h.configPull()
        ..['licenseToken'] = forged;
      await expectLater(h.hub.applyConfig(pull), throwsA(isA<HubError>()));
      expect(await h.hub.db.getMeta('license_token'), isNot(forged));
    });

    test('grace keeps full access; past expiry + 7 days the hub is read-only without the cloud', () async {
      await h.hub.setLicenseToken(await h.license(expDays: -3)); // in grace
      expect((await h.post('/orders', session: cashier, body: {'type': 'takeaway'})).status, 201);
      await h.hub.setLicenseToken(await h.license(expDays: -8)); // past grace
      final r = await h.post('/orders', session: cashier, body: {'type': 'takeaway'});
      expect(r.code, 'license_read_only');
      expect((await h.get('/state')).status, 200); // history still readable
    });
  });

  group('orders', () {
    test('dine-in: price snapshots survive menu changes; KOT locks lines; takeaway has no table', () async {
      final id = await openDineIn(Harness.t1);
      expect((await h.post('/orders', session: cashier, body: {'type': 'dine_in', 'tableId': Harness.t1})).code, 'table_occupied');
      final o = await add(id, [{'menuItemId': Harness.butterChicken, 'qty': 1}, {'menuItemId': Harness.naan, 'qty': 2, 'notes': 'extra butter'}]);
      final pull = await h.configPull();
      ((pull['items']! as List).first as Map)['pricePaise'] = 99900; // menu price changes later
      await h.hub.applyConfig(pull);
      final again = (await h.get('/orders/$id', session: cashier)).json;
      expect(((again['lines']! as List).first as Map)['price_snapshot_paise'], 34000);
      expect((again['totals']! as Map)['totalPaise'], 48300); // 340 + 120 + 5% = 483
      final lineId = ((o['lines']! as List)[1] as Map)['id'];
      expect((await h.patch('/orders/$id/lines/$lineId', session: cashier, body: {'qty': 3})).status, 200);
      final kot = await h.post('/orders/$id/kot', session: cashier);
      expect(kot.json['kotNo'], 1);
      expect((await h.patch('/orders/$id/lines/$lineId', session: cashier, body: {'qty': 1})).code, 'line_sent');
      final tk = await h.post('/orders', session: cashier, body: {'type': 'takeaway'});
      expect(tk.json['table_id'], isNull);
      expect((await h.post('/orders', session: cashier, body: {'type': 'takeaway', 'tableId': Harness.t2})).code, 'no_table_for_takeaway');
    });

    test('stale version is rejected (two terminals editing the same order)', () async {
      final id = await openDineIn(Harness.t1);
      final r1 = await h.post('/orders/$id/lines', session: cashier, body: {'version': 1, 'lines': [{'menuItemId': Harness.naan, 'qty': 1}]});
      expect(r1.status, 201);
      final r2 = await h.post('/orders/$id/lines', session: cashier, body: {'version': 1, 'lines': [{'menuItemId': Harness.naan, 'qty': 1}]});
      expect(r2.code, 'stale_version');
    });
  });

  group('menu sizes / portions (variants)', () {
    Future<void> withSizes({int halfPrice = 22000, bool halfAvailable = true}) async {
      final pull = await h.configPull();
      pull['categories'] = [
        {'id': 'c1', 'name': 'Mains', 'sortOrder': 0, 'deleted': false, 'active': true},
        {'id': 'c9', 'name': 'Hidden', 'sortOrder': 1, 'deleted': false, 'active': false},
      ];
      (pull['items']! as List).add({'id': 'hidden-item', 'categoryId': 'c9', 'name': 'Secret', 'pricePaise': 100, 'taxRuleId': 'tx5', 'available': true, 'isVeg': true, 'deleted': false});
      pull['variants'] = [
        {'id': 'v-q', 'itemId': Harness.butterChicken, 'code': 'BC-Q', 'name': 'Quarter plate', 'portionLabel': 'quarter', 'servingQuantity': 1, 'servingUnit': 'plate', 'pricePaise': 12000, 'taxRuleId': null, 'available': true, 'isDefault': false, 'sortOrder': 0, 'deleted': false},
        {'id': 'v-h', 'itemId': Harness.butterChicken, 'code': 'BC-H', 'name': 'Half plate', 'portionLabel': 'half', 'servingQuantity': 1, 'servingUnit': 'plate', 'pricePaise': halfPrice, 'taxRuleId': null, 'available': halfAvailable, 'isDefault': false, 'sortOrder': 1, 'deleted': false},
        {'id': 'v-f', 'itemId': Harness.butterChicken, 'code': 'BC-F', 'name': 'Full plate', 'portionLabel': 'full', 'servingQuantity': 1, 'servingUnit': 'plate', 'pricePaise': 40000, 'taxRuleId': null, 'available': true, 'isDefault': true, 'sortOrder': 2, 'deleted': false},
        {'id': 'v-500', 'itemId': Harness.lassi, 'code': 'LASSI-500', 'name': '500 ml', 'servingQuantity': 500, 'servingUnit': 'ml', 'pricePaise': 15000, 'taxRuleId': 'tx5', 'available': true, 'isDefault': true, 'sortOrder': 0, 'deleted': false},
      ];
      await h.hub.applyConfig(pull);
    }

    test('the POS menu lists each size with its own price; inactive categories are hidden', () async {
      await withSizes();
      final menu = (await h.get('/menu', session: cashier)).json;
      final items = (menu['items']! as List).cast<Map<String, Object?>>();
      expect(items.any((i) => i['name'] == 'Secret'), isFalse);
      expect((menu['categories']! as List).length, 1);
      final bc = items.firstWhere((i) => i['id'] == Harness.butterChicken);
      expect([for (final v in (bc['variants']! as List).cast<Map<String, Object?>>()) (v['name'], v['price_paise'])], [('Quarter plate', 12000), ('Half plate', 22000), ('Full plate', 40000)]);
      final lassi = items.firstWhere((i) => i['id'] == Harness.lassi);
      expect(((lassi['variants']! as List).single as Map)['rate_bp'], 500, reason: 'variant tax overrides the item tax');
    });

    test('ordering a size uses its price, tax and name; the snapshot survives later price changes; KOT and bill show the size', () async {
      await withSizes();
      final id = await openDineIn(Harness.t1);
      final o = await add(id, [
        {'menuItemId': Harness.butterChicken, 'variantId': 'v-h', 'qty': 2},
        {'menuItemId': Harness.lassi, 'qty': 1}, // no size sent: the default
        {'menuItemId': Harness.naan, 'qty': 1}, // an item without sizes still works
      ]);
      final lines = (o['lines']! as List).cast<Map<String, Object?>>();
      final half = lines.firstWhere((l) => l['variant_id'] == 'v-h');
      expect((half['name_snapshot'], half['price_snapshot_paise'], half['variant_code_snapshot']), ('Butter Chicken · Half plate', 22000, 'BC-H'));
      final lassi = lines.firstWhere((l) => l['menu_item_id'] == Harness.lassi);
      expect((lassi['variant_id'], lassi['price_snapshot_paise'], lassi['tax_rate_snapshot_bp']), ('v-500', 15000, 500));
      expect(lines.firstWhere((l) => l['menu_item_id'] == Harness.naan)['price_snapshot_paise'], 6000);
      await withSizes(halfPrice: 25000); // owner raises the price later
      final again = (await h.get('/orders/$id', session: cashier)).json;
      expect((again['lines']! as List).cast<Map<String, Object?>>().firstWhere((l) => l['variant_id'] == 'v-h')['price_snapshot_paise'], 22000);
      expect((await h.post('/orders/$id/kot', session: cashier)).status, 201);
      final kds = (await h.get('/kds/tickets', session: cashier)).body;
      expect(jsonEncode(kds), contains('Butter Chicken · Half plate'));
      final outbox = await h.hub.db.query("SELECT payload FROM sync_outbox WHERE entity = 'order_line'");
      expect(outbox.map((r) => jsonDecode(r['payload']! as String)['variant_code_snapshot']), contains('BC-H'));
      // the bill is built from the snapshots: 2 half plates at the old price + lassi 500 ml + naan
      final bill = await h.post('/orders/$id/bill', session: cashier, body: {});
      expect(bill.status, anyOf(200, 201), reason: '$bill');
      expect((bill.json['bill'] as Map? ?? bill.json)['subtotal_paise'], 2 * 22000 + 15000 + 6000);
    });

    test('an unavailable or unknown size is refused', () async {
      await withSizes(halfAvailable: false);
      final id = await openDineIn(Harness.t1);
      final r = await h.post('/orders/$id/lines', session: cashier, body: {'lines': [{'menuItemId': Harness.butterChicken, 'variantId': 'v-h', 'qty': 1}]});
      expect(r.code, 'item_unavailable');
      final r2 = await h.post('/orders/$id/lines', session: cashier, body: {'lines': [{'menuItemId': Harness.butterChicken, 'variantId': 'v-500', 'qty': 1}]});
      expect(r2.status, 404, reason: "another item's size");
    });
  });

  test('floor plan: tables carry shape, position and chairs; reserved shows, unavailable refuses new orders', () async {
    final pull = await h.configPull();
    pull['floors'] = [{'id': 'f1', 'name': 'Ground', 'sortOrder': 0, 'deleted': false, 'width': 1500, 'height': 900}];
    pull['tables'] = [
      {'id': Harness.t1, 'floorId': 'f1', 'name': '1', 'seats': 2, 'layoutX': 0, 'layoutY': 0, 'deleted': false, 'shape': 'round', 'posX': 150, 'posY': 150, 'width': 80, 'height': 80, 'rotation': 0, 'chairs': [{'x': -60, 'y': 0, 'rotation': 90}], 'status': 'reserved'},
      {'id': Harness.t2, 'floorId': 'f1', 'name': '2', 'seats': 6, 'layoutX': 2, 'layoutY': 0, 'deleted': false, 'shape': 'rect', 'posX': 400, 'posY': 150, 'width': 160, 'height': 80, 'rotation': 90, 'chairs': null, 'status': 'unavailable'},
      {'id': Harness.t3, 'floorId': 'f1', 'name': '3', 'seats': 4, 'layoutX': 4, 'layoutY': 0, 'deleted': false}, // from an older cloud
    ];
    await h.hub.applyConfig(pull);
    final st = (await h.get('/state', session: cashier)).json;
    expect((st['floors']! as List).cast<Map<String, Object?>>().single['width'], 1500);
    final tables = {for (final t in (st['tables']! as List).cast<Map<String, Object?>>()) t['name']: t};
    expect((tables['1']!['shape'], tables['1']!['pos_x'], tables['1']!['status'], (tables['1']!['chairs'] as List).length), ('round', 150, 'reserved', 1));
    expect((tables['2']!['rotation'], tables['2']!['status']), (90, 'unavailable'));
    expect((tables['3']!['pos_x'], tables['3']!['shape']), (420, 'square'), reason: 'legacy grid position is placed on the plan');
    expect((await h.post('/orders', session: cashier, body: {'type': 'dine_in', 'tableId': Harness.t2})).code, 'table_unavailable');
    final id = await openDineIn(Harness.t1); // a reserved table seats its guests
    final st2 = (await h.get('/state', session: cashier)).json;
    expect((st2['tables']! as List).cast<Map<String, Object?>>().firstWhere((t) => t['id'] == Harness.t1)['status'], 'occupied');
    expect((await h.post('/orders/$id/transfer', session: cashier, body: {'toTableId': Harness.t2})).code, 'table_unavailable');
  });

  group('AC-04 table transfer', () {
    test('moves once with all lines and timestamps; occupied target is a conflict', () async {
      final a = await openDineIn(Harness.t1);
      final b = await openDineIn(Harness.t2);
      final before = await add(a, [{'menuItemId': Harness.butterChicken, 'qty': 1}, {'menuItemId': Harness.lassi, 'qty': 2}]);
      await h.post('/orders/$a/kot', session: cashier);
      final occ = await h.post('/orders/$a/transfer', session: cashier, body: {'toTableId': Harness.t2});
      expect(occ.status, 409);
      expect(occ.code, 'table_occupied');
      final ok = await h.post('/orders/$a/transfer', session: cashier, body: {'toTableId': Harness.t3});
      expect(ok.status, 200, reason: '$ok');
      expect(ok.json['table_id'], Harness.t3);
      expect(ok.json['opened_at'], before['opened_at']);
      final lines = (ok.json['lines']! as List).cast<Map<String, Object?>>();
      expect(lines.map((l) => l['id']), (before['lines']! as List).map((l) => (l as Map)['id']));
      expect(lines.every((l) => l['status'] == 'sent'), isTrue);
      final state = (await h.get('/state')).json;
      final tables = {for (final t in (state['tables']! as List).cast<Map<String, Object?>>()) t['id']: t['status']};
      expect(tables, {Harness.t1: 'free', Harness.t2: 'occupied', Harness.t3: 'occupied'});
      final rows = await h.hub.db.query('SELECT * FROM table_transfers WHERE order_id = ?', [a]);
      expect(rows, hasLength(1));
      expect(await h.hub.db.query("SELECT * FROM audit_events WHERE action = 'order.transferred'"), hasLength(1));
      expect(b, isNotEmpty);
    });

    test('two simultaneous transfers → exactly one wins; the order is never on two tables', () async {
      final a = await openDineIn(Harness.t1);
      final c = await openDineIn(Harness.t2);
      // same order to two tables at once
      final r = await Future.wait([
        h.post('/orders/$a/transfer', session: cashier, body: {'toTableId': Harness.t3, 'version': 1}),
        h.post('/orders/$a/transfer', session: owner, body: {'toTableId': Harness.t3, 'version': 1}),
      ]);
      expect(r.map((x) => x.status).toList()..sort(), [200, 409]);
      // two orders racing for the same free table
      final t3Free = await h.post('/orders/$a/transfer', session: cashier, body: {'toTableId': Harness.t1});
      expect(t3Free.status, 200);
      final race = await Future.wait([
        h.post('/orders/$a/transfer', session: cashier, body: {'toTableId': Harness.t3}),
        h.post('/orders/$c/transfer', session: owner, body: {'toTableId': Harness.t3}),
      ]);
      expect(race.map((x) => x.status).toList()..sort(), [200, 409]);
      final live = await h.hub.db.query("SELECT table_id, count(*) AS n FROM orders WHERE status IN ('open','billed') GROUP BY table_id");
      expect(live.every((x) => x['n'] == 1), isTrue);
    });
  });

  group('AC-05 reversal', () {
    test('no reason → rejected; with reason → traced (actor, time, amount) and totals drop', () async {
      final id = await openDineIn(Harness.t1);
      final o = await add(id, [{'menuItemId': Harness.butterChicken, 'qty': 1}, {'menuItemId': Harness.naan, 'qty': 2}]);
      final naanLine = ((o['lines']! as List)[1] as Map)['id'];
      expect((await h.post('/orders/$id/lines/$naanLine/reverse', session: cashier, body: {})).code, 'reason_required');
      expect((await h.post('/orders/$id/lines/$naanLine/reverse', session: cashier, body: {'reason': '  '})).code, 'reason_required');
      final r = await h.post('/orders/$id/lines/$naanLine/reverse', session: cashier, body: {'reason': 'Guest changed mind'});
      expect(r.status, 200, reason: '$r');
      expect((r.json['totals']! as Map)['totalPaise'], 35700);
      final line = await h.hub.db.selectOne('SELECT * FROM order_lines WHERE id = ?', [naanLine]);
      expect(line, containsPair('status', 'reversed'));
      expect(line, containsPair('reversed_by', Harness.cashier));
      expect(line, containsPair('reversal_reason', 'Guest changed mind'));
      expect(line!['reversed_at'], isNotNull);
      final audit = await h.hub.db.selectOne("SELECT * FROM audit_events WHERE action = 'order.line_reversed'");
      expect(jsonDecode(audit!['after_json']! as String), containsPair('amountPaise', 12000));
      expect(audit['reason'], 'Guest changed mind');
      final ob = await h.hub.db.query("SELECT * FROM sync_outbox WHERE entity = 'order_line' AND op = 'reverse'");
      expect(ob, hasLength(1));
    });

    test('a sent line needs an owner/manager PIN; the approver is recorded', () async {
      final id = await openDineIn(Harness.t1);
      final o = await add(id, [{'menuItemId': Harness.butterChicken, 'qty': 1}]);
      final lineId = ((o['lines']! as List).first as Map)['id'];
      await h.post('/orders/$id/kot', session: cashier);
      expect((await h.post('/orders/$id/lines/$lineId/reverse', session: cashier, body: {'reason': 'Burnt'})).code, 'approval_required');
      expect((await h.post('/orders/$id/lines/$lineId/reverse', session: cashier, body: {'reason': 'Burnt', 'approverUserId': Harness.owner, 'approverPin': '0000'})).code, 'approval_denied');
      expect((await h.post('/orders/$id/lines/$lineId/reverse', session: cashier, body: {'reason': 'Burnt', 'approverUserId': Harness.waiter, 'approverPin': '5555'})).code, 'approval_denied');
      final ok = await h.post('/orders/$id/lines/$lineId/reverse', session: cashier, body: {'reason': 'Burnt', 'approverUserId': Harness.owner, 'approverPin': '9999'});
      expect(ok.status, 200);
      expect(ok.json['status'], 'cancelled'); // every line reversed → order cancelled, table freed
      expect((await h.hub.db.selectOne('SELECT reversal_approved_by FROM order_lines WHERE id = ?', [lineId]))!['reversal_approved_by'], Harness.owner);
    });

    test('reversal on a billed (unpaid) order adjusts the bill via a BillAdjustment; paid bills refuse it', () async {
      final id = await openDineIn(Harness.t1);
      final o = await add(id, [{'menuItemId': Harness.butterChicken, 'qty': 1}, {'menuItemId': Harness.naan, 'qty': 1}]);
      final naanLine = ((o['lines']! as List)[1] as Map)['id'];
      final bill = (await h.post('/orders/$id/bill', session: cashier)).json;
      expect(bill['total_paise'], 42000); // 400 + 20 = 420
      final r = await h.post('/orders/$id/lines/$naanLine/reverse', session: owner, body: {'reason': 'Not served'});
      expect(r.status, 200, reason: '$r');
      expect((r.json['adjustment']! as Map)['amount_paise'], -6300);
      expect((r.json['bill']! as Map)['total_paise'], 35700);
      final pay = await h.post('/bills/${bill['id']}/payments', session: cashier, idem: 'pay-key-0001', body: {'mode': 'cash', 'tenderedPaise': 40000});
      expect(pay.json['changePaise'], 4300);
      final o2 = await add(await openDineIn(Harness.t1), [{'menuItemId': Harness.naan, 'qty': 1}]);
      expect(o2, isNotEmpty);
      expect((await h.post('/orders/$id/lines/${((o['lines']! as List)[0] as Map)['id']}/reverse', session: owner, body: {'reason': 'late'})).code, 'bill_paid');
    });
  });

  group('bills, discounts, invoice numbers', () {
    test('invoice numbers are per branch per FY and gap-free', () async {
      final nos = <String>[];
      for (final t in [Harness.t1, Harness.t2, Harness.t3]) {
        final id = await openDineIn(t);
        await add(id, [{'menuItemId': Harness.naan, 'qty': 1}]);
        nos.add((await h.post('/orders/$id/bill', session: cashier)).json['invoice_no']! as String);
      }
      expect(nos, ['BR01/26-27/000001', 'BR01/26-27/000002', 'BR01/26-27/000003']);
      h.now = DateTime.utc(2027, 4, 1, 1); // next FY (06:30 IST, 1 Apr)
      await h.hub.setLicenseToken(await h.license()); // renewed licence for the new year
      cashier = await h.login(Harness.cashier); // yesterday's session has expired
      final tk = (await h.post('/orders', session: cashier, body: {'type': 'takeaway'})).json['id'];
      await add(tk as String, [{'menuItemId': Harness.naan, 'qty': 1}]);
      expect((await h.post('/orders/$tk/bill', session: cashier)).json['invoice_no'], 'BR01/27-28/000001');
    });

    test('discount needs discount.apply; above 10% needs a reason', () async {
      final id = await openDineIn(Harness.t1);
      await add(id, [{'menuItemId': Harness.butterChicken, 'qty': 1}]);
      expect((await h.post('/orders/$id/bill', session: cashier, body: {'discount': {'type': 'percent', 'bp': 500}})).code, 'missing_permission');
      final meera = await h.login(Harness.discountCashier);
      expect((await h.post('/orders/$id/bill', session: meera, body: {'discount': {'type': 'percent', 'bp': 1500}})).code, 'reason_required');
      final ok = await h.post('/orders/$id/bill', session: meera, body: {'discount': {'type': 'percent', 'bp': 1500}, 'discountReason': 'Regular guest'});
      expect(ok.status, 201, reason: '$ok');
      expect(ok.json['discount_paise'], 5100);
      expect(ok.json['total_paise'], 30300); // 289 + 5% = 303.45 → 303
    });
  });

  group('AC-06 tips', () {
    test('tip lands on the selected waiter and shows in the tips report; defaults to the order waiter', () async {
      final id = await openDineIn(Harness.t1, waiterId: Harness.waiter);
      await add(id, [{'menuItemId': Harness.butterChicken, 'qty': 1}]);
      final bill = (await h.post('/orders/$id/bill', session: cashier)).json;
      final t = await h.post('/bills/${bill['id']}/tip', session: cashier, body: {'amountPaise': 3000, 'waiterId': Harness.waiter2});
      expect(t.status, 200, reason: '$t');
      expect(t.json['waiterId'], Harness.waiter2);
      expect((t.json['totals']! as Map)['totalPaise'], 38700); // 357 + 30 tip, untaxed
      final again = await h.post('/bills/${bill['id']}/tip', session: cashier, body: {'amountPaise': 2000});
      expect(again.json['waiterId'], Harness.waiter); // default = order's waiter
      expect((await h.post('/bills/${bill['id']}/tip', session: cashier, body: {'amountPaise': 2000, 'waiterId': Harness.chef})).code, 'not_a_waiter');
      final report = (await h.get('/reports/tips', session: cashier)).body! as List;
      expect(report, [{'waiter_id': Harness.waiter, 'waiter_name': 'Anita', 'tip_paise': 2000, 'bills': 1}]);
    });

    test('dine-in tip without any waiter prompts for one', () async {
      final r = await h.post('/orders', session: cashier, body: {'type': 'dine_in', 'tableId': Harness.t2});
      final id = r.json['id']! as String;
      await add(id, [{'menuItemId': Harness.naan, 'qty': 1}]);
      final bill = (await h.post('/orders/$id/bill', session: cashier)).json;
      expect((await h.post('/bills/${bill['id']}/tip', session: cashier, body: {'amountPaise': 1000})).code, 'waiter_required');
    });
  });

  group('AC-07-lite payments', () {
    test('same idempotency key twice → one payment, same result', () async {
      final id = await openDineIn(Harness.t1);
      await add(id, [{'menuItemId': Harness.butterChicken, 'qty': 1}]);
      final bill = (await h.post('/orders/$id/bill', session: cashier)).json;
      expect((await h.post('/bills/${bill['id']}/payments', session: cashier, body: {'mode': 'upi', 'amountPaise': 10000})).code, 'idempotency_key_required');
      final p1 = await h.post('/bills/${bill['id']}/payments', session: cashier, idem: 'terminal1-0001', body: {'mode': 'upi', 'amountPaise': 10000});
      final p2 = await h.post('/bills/${bill['id']}/payments', session: cashier, idem: 'terminal1-0001', body: {'mode': 'upi', 'amountPaise': 10000});
      expect(p1.status, 201);
      expect(p2.status, 200);
      expect(p2.json['paymentId'], p1.json['paymentId']);
      expect(p2.json['replayed'], isTrue);
      // concurrent retries of one key also produce one row
      await Future.wait([
        for (var i = 0; i < 5; i++) h.post('/bills/${bill['id']}/payments', session: cashier, idem: 'terminal1-0002', body: {'mode': 'card', 'amountPaise': 5000}),
      ]);
      final rows = await h.hub.db.query('SELECT * FROM payments WHERE bill_id = ?', [bill['id']]);
      expect(rows, hasLength(2));
      // pay the rest across modes, with change
      final last = await h.post('/bills/${bill['id']}/payments', session: cashier, idem: 'terminal1-0003', body: {'mode': 'cash', 'tenderedPaise': 50000});
      expect(last.json, containsPair('amountPaise', 20700));
      expect(last.json, containsPair('changePaise', 29300));
      expect(last.json, containsPair('billStatus', 'paid'));
      expect((await h.post('/bills/${bill['id']}/payments', session: cashier, idem: 'terminal1-0004', body: {'mode': 'upi', 'amountPaise': 100})).code, 'bill_paid');
      final st = (await h.get('/state')).json;
      expect(((st['tables']! as List).first as Map)['status'], 'free');
    });

    test('UPI cannot overpay; waiter cannot take payment', () async {
      final id = await openDineIn(Harness.t1);
      await add(id, [{'menuItemId': Harness.naan, 'qty': 1}]);
      final bill = (await h.post('/orders/$id/bill', session: cashier)).json;
      expect((await h.post('/bills/${bill['id']}/payments', session: cashier, idem: 'k-000000001', body: {'mode': 'upi', 'amountPaise': 99999})).code, 'overpayment');
      final w = await h.login(Harness.waiter);
      expect((await h.post('/bills/${bill['id']}/payments', session: w, idem: 'k-000000002', body: {'mode': 'cash', 'tenderedPaise': 10000})).code, 'missing_permission');
    });

    test('paid bills are immutable; corrections are adjustments with reason + approval', () async {
      final id = await openDineIn(Harness.t1);
      await add(id, [{'menuItemId': Harness.naan, 'qty': 1}]);
      final bill = (await h.post('/orders/$id/bill', session: cashier)).json;
      await h.post('/bills/${bill['id']}/payments', session: cashier, idem: 'adj-000001', body: {'mode': 'cash', 'tenderedPaise': 10000});
      await expectLater(h.hub.db.execute('UPDATE bills SET total_paise = 1 WHERE id = ?', [bill['id']]), throwsA(anything));
      expect((await h.post('/bills/${bill['id']}/adjustments', session: cashier, body: {'amountPaise': -1000})).code, 'reason_required');
      expect((await h.post('/bills/${bill['id']}/adjustments', session: cashier, body: {'amountPaise': -1000, 'reason': 'Overcharged'})).code, 'approval_required');
      final ok = await h.post('/bills/${bill['id']}/adjustments', session: cashier, body: {'amountPaise': -1000, 'reason': 'Overcharged', 'approverUserId': Harness.owner, 'approverPin': '9999'});
      expect(ok.status, 201, reason: '$ok');
      expect(ok.json['approved_by'], Harness.owner);
      expect((await h.hub.db.selectOne('SELECT total_paise FROM bills WHERE id = ?', [bill['id']]))!['total_paise'], 6300);
    });
  });

  group('outbox & sync', () {
    test('every write appends outbox events in the same transaction', () async {
      final id = await openDineIn(Harness.t1);
      await add(id, [{'menuItemId': Harness.naan, 'qty': 1}]);
      final ev = await h.hub.db.query('SELECT entity, op FROM sync_outbox ORDER BY seq');
      expect(ev.map((e) => '${e['entity']}.${e['op']}'), containsAll(['order.create', 'order_status.create', 'order_line.create', 'order.update']));
      final payload = jsonDecode((await h.hub.db.selectOne("SELECT payload FROM sync_outbox WHERE entity = 'order'"))!['payload']! as String);
      expect(payload, containsPair('branchId', Harness.branchId));
    });

    test('the same batch pushed twice is stored once (lost response, then retry)', () async {
      final cloud = FakeCloud();
      final worker = SyncWorker(h.hub.db, h.hub, CloudClient('http://cloud', 'dev-token', client: cloud.client()));
      final id = await openDineIn(Harness.t1);
      await add(id, [{'menuItemId': Harness.naan, 'qty': 2}]);
      final total = (await h.hub.db.selectOne('SELECT count(*) AS n FROM sync_outbox'))!['n']! as int;

      cloud.dropNextResponse = true; // cloud stores the batch but the hub never hears back
      final first = await worker.pushOnce();
      expect(first.ok, isFalse);
      expect(worker.consecutiveFailures, 1);
      expect(cloud.stored.length, total);
      expect((await h.hub.syncStatus())['pending'], total);

      final second = await worker.pushOnce(); // same events again
      expect(second.ok, isTrue);
      expect(second.duplicate, total);
      expect(cloud.stored.length, total); // stored once
      expect(cloud.received, total * 2);
      expect((await h.hub.syncStatus())['pending'], 0);
      expect((await h.hub.syncStatus())['pushed'], total);
      expect((await worker.pushOnce()).sent, 0);
    });

    test('rejected events are marked failed and not retried; backoff grows to 5 minutes while offline', () async {
      final cloud = FakeCloud()..rejectEntity = 'audit_event';
      final worker = SyncWorker(h.hub.db, h.hub, CloudClient('http://cloud', 'dev-token', client: cloud.client()));
      final id = await openDineIn(Harness.t1);
      final o = await add(id, [{'menuItemId': Harness.naan, 'qty': 1}]);
      await h.post('/orders/$id/lines/${((o['lines']! as List).first as Map)['id']}/reverse', session: cashier, body: {'reason': 'Wrong item'});
      final out = await worker.pushOnce();
      expect(out.rejected, greaterThan(0));
      expect((await h.hub.syncStatus())['failed'], out.rejected);
      expect((await worker.pushOnce()).sent, 0);

      cloud.offline = true;
      await openDineIn(Harness.t2);
      final delays = <int>[];
      for (var i = 0; i < 12; i++) {
        await worker.pushOnce();
        delays.add(worker.currentDelay.inSeconds);
      }
      expect(delays.take(4), [1, 2, 4, 8]);
      expect(delays.last, 300);
      cloud.offline = false;
      expect((await worker.pushOnce()).ok, isTrue);
      expect(worker.currentDelay, const Duration(seconds: 5));
    });

    test('config pull applies changes since the cursor', () async {
      final cloud = FakeCloud()..pullBody = await h.configPull();
      final worker = SyncWorker(h.hub.db, h.hub, CloudClient('http://cloud', 'dev-token', client: cloud.client()));
      await worker.pullOnce();
      expect(cloud.lastSince, '42');
      expect(await h.hub.db.getMeta('last_pull_at'), isNotNull);
    });
  });

  test('menu photos: prefetched after a pull, served by the hub, still there when the cloud is offline', () async {
    const photo = 'a1b2c3d4-0000-7000-8000-00000000f070';
    final pull = await h.configPull();
    final items = (pull['items']! as List).cast<Map<String, Object?>>();
    items.first['imageId'] = photo;
    final cloud = FakeCloud()
      ..pullBody = pull
      ..media[photo] = [0x89, 0x50, 0x4e, 0x47, 1, 2, 3];
    final worker = SyncWorker(h.hub.db, h.hub, CloudClient('http://cloud', 'dev-token', client: cloud.client()));
    await worker.pullOnce();
    expect(cloud.mediaFetches, 1, reason: 'prefetched right after the pull');
    final menu = (await h.get('/menu')).json;
    expect((menu['items']! as List).cast<Map<String, Object?>>().firstWhere((i) => i['id'] == items.first['id'])['image_id'], photo);
    cloud.offline = true;
    final r = await http.get(Uri.parse('${h.base}/media/$photo'), headers: h.headers());
    expect(r.statusCode, 200);
    expect(r.headers['content-type'], 'image/png');
    expect(r.bodyBytes, [0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
    expect(cloud.mediaFetches, 1, reason: 'served from the cache');
    expect((await http.get(Uri.parse('${h.base}/media/not-on-our-menu'), headers: h.headers())).statusCode, 404);
    expect((await http.get(Uri.parse('${h.base}/media/$photo'))).statusCode, 401, reason: 'paired devices only');
  });

  test('restaurant logo (branding): prefetched, served offline, and in the branch info the POS themes itself from', () async {
    const logo = 'a1b2c3d4-0000-7000-8000-00000000b0b0';
    final pull = await h.configPull();
    pull['tenant'] = {...(pull['tenant']! as Map<String, Object?>), 'branding': {'color': '#1A73E8', 'textSize': 'large', 'headingWeight': 'bold', 'headingCase': 'normal', 'logoImageId': logo}};
    final cloud = FakeCloud()
      ..pullBody = pull
      ..media[logo] = [0x89, 0x50, 0x4e, 0x47, 9, 9];
    final worker = SyncWorker(h.hub.db, h.hub, CloudClient('http://cloud', 'dev-token', client: cloud.client()));
    await worker.pullOnce();
    expect(cloud.mediaFetches, 1, reason: 'logo prefetched right after the pull');
    final info = (await h.get('/branch')).json;
    expect(((info['tenant']! as Map)['branding']! as Map)['color'], '#1A73E8');
    cloud.offline = true;
    final r = await http.get(Uri.parse('${h.base}/media/$logo'), headers: h.headers());
    expect(r.statusCode, 200);
    expect(r.bodyBytes, [0x89, 0x50, 0x4e, 0x47, 9, 9]);
  });

  test('WebSocket: snapshot on connect, then live events', () async {
    final ws = IOWebSocketChannel.connect(Uri.parse('${h.base.replaceFirst('http', 'ws')}/events'), headers: {'x-device-token': h.deviceToken});
    final msgs = StreamIterator(ws.stream.map((m) => jsonDecode(m as String) as Map<String, Object?>));
    expect(await msgs.moveNext(), isTrue);
    expect(msgs.current['type'], 'state.snapshot');
    await openDineIn(Harness.t1);
    expect(await msgs.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect(msgs.current['type'], 'table.status_changed');
    expect(msgs.current['branch_id'], Harness.branchId);
    expect(msgs.current['event_id'], isNotNull);
    await ws.sink.close();
  });

  test('TLS: clients reach the hub only when the pinned fingerprint matches', () async {
    final tls = HubTls.generate();
    final server = HubServer(h.hub, hubName: 'TLS hub', certFingerprint: tls.fingerprint);
    final s = await server.start(address: InternetAddress.loopbackIPv4, port: 0, tls: tls.context());
    final pinned = HubTls.pinnedClient(tls.fingerprint);
    final req = await pinned.getUrl(Uri.parse('https://127.0.0.1:${s.port}/hub/v1/pairing/info'));
    final res = await req.close();
    expect(res.statusCode, 200);
    expect((jsonDecode(await res.transform(utf8.decoder).join()) as Map)['certFingerprint'], tls.fingerprint);
    final wrong = HubTls.pinnedClient('00:11');
    await expectLater(() async => (await wrong.getUrl(Uri.parse('https://127.0.0.1:${s.port}/hub/v1/health'))).close(), throwsA(isA<HandshakeException>()));
    pinned.close(force: true);
    wrong.close(force: true);
    await server.stop();
  });
}
