import 'dart:async';
import 'dart:convert';

import 'package:rsaas_core/rsaas_core.dart';

import 'db.dart';
import 'license.dart';
import 'permissions.dart';
import 'pin.dart';
import 'util.dart';

/// Who is acting: a paired device plus (for staff actions) a signed-in user.
class Actor {
  const Actor({required this.deviceId, this.userId, this.permissions = const {}});
  final String deviceId;
  final String? userId;
  final Set<String> permissions;

  String get id => userId ?? 'device:$deviceId';
  void require(String permission) {
    if (!permissions.contains(permission)) throw forbidden('missing_permission', 'Missing permission: $permission');
  }
}

class HubConfig {
  const HubConfig({required this.branchId, required this.branchCode, required this.licensePublicKey, this.discountReasonAboveBp = 1000});
  final String branchId;
  final String branchCode;

  /// Cloud LICENSE_PUBLIC_KEY (SPKI DER base64) — verifies license tokens offline.
  final String licensePublicKey;

  /// Discounts above this percentage (basis points) need a reason (Chef's Defaults: 10%).
  final int discountReasonAboveBp;
}

/// A change other terminals should see (sent over the WebSocket bus after the transaction commits).
class HubEvent {
  HubEvent(this.type, this.data) : eventId = uuidv7(), at = nowIso();
  final String eventId;
  final String type;
  final String at;
  final Map<String, Object?> data;
  Map<String, Object?> toJson(String branchId) => {'event_id': eventId, 'type': type, 'branch_id': branchId, 'at': at, 'data': data};
}

/// Single writer for live operations in a branch. Every write runs in one SQLite transaction together with
/// its outbox event(s) and audit event, so the cloud receives exactly what happened, once.
class HubService {
  HubService(this.db, this.config, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now,
        _verifier = LicenseVerifier(config.licensePublicKey);

  final HubDatabase db;
  final HubConfig config;
  final DateTime Function() clock;
  final LicenseVerifier _verifier;
  final _events = StreamController<HubEvent>.broadcast();
  Stream<HubEvent> get events => _events.stream;

  // ------------------------------------------------------------------ outbox, audit, events

  List<HubEvent>? _pending;

  /// Runs [fn] in a transaction; events raised inside are published only after commit.
  Future<T> _tx<T>(Future<T> Function() fn) async {
    final outer = _pending == null;
    if (outer) _pending = [];
    try {
      final r = await db.transaction(fn);
      if (outer) {
        for (final e in _pending!) {
          _events.add(e);
        }
      }
      return r;
    } finally {
      if (outer) _pending = null;
    }
  }

  void _raise(String type, Map<String, Object?> data) => _pending?.add(HubEvent(type, data));

  Future<void> _outbox(String entity, String entityId, String op, Map<String, Object?> payload) => db.execute(
        'INSERT INTO sync_outbox(event_id, entity, entity_id, op, payload, created_at) VALUES (?,?,?,?,?,?)',
        [uuidv7(), entity, entityId, op, jsonEncode({...payload, 'branchId': config.branchId}), nowIso(clock())],
      );

  Future<void> _audit(Actor a, String action, {String? objectType, String? objectId, Object? before, Object? after, String? reason}) async {
    final id = uuidv7();
    final row = {
      'id': id, 'actor': a.id, 'action': action, 'objectType': objectType, 'objectId': objectId,
      'before': before, 'after': after, 'reason': reason, 'deviceId': a.deviceId, 'at': nowIso(clock()),
    };
    await db.execute(
      'INSERT INTO audit_events(id, actor, action, object_type, object_id, before_json, after_json, reason, device_id, at) VALUES (?,?,?,?,?,?,?,?,?,?)',
      [id, a.id, action, objectType, objectId, before == null ? null : jsonEncode(before), after == null ? null : jsonEncode(after), reason, a.deviceId, row['at']],
    );
    await _outbox('audit_event', id, 'create', row);
  }

  // ------------------------------------------------------------------ license (verified offline)

  Map<String, Object?>? _licenseCache;
  String? _licenseCacheToken;

  /// Saves a license token only if its signature verifies against the cloud key.
  Future<void> setLicenseToken(String token) async {
    final p = await _verifier.verify(token);
    if (p == null) throw forbidden('license_invalid', 'License token signature is invalid');
    await db.setMeta('license_token', token);
  }

  Future<({LicenseState state, List<String> features, Map<String, Object?>? payload})> license() async {
    final token = await db.getMeta('license_token');
    if (token == null) return (state: LicenseState.invalid, features: const <String>[], payload: null);
    if (token != _licenseCacheToken) {
      _licenseCache = await _verifier.verify(token);
      _licenseCacheToken = token;
    }
    final p = _licenseCache;
    return (state: licenseState(p, clock()), features: ((p?['features'] as List?) ?? const []).cast<String>(), payload: p);
  }

  /// Refuses gated actions when the signed token is invalid, lacks the flag, or is past expiry + grace (AC-02).
  Future<void> requireFeature(String flag) async {
    final l = await license();
    if (l.state == LicenseState.invalid) throw forbidden('license_invalid', 'No valid license on this hub');
    if (!l.features.contains(flag)) throw forbidden('feature_not_in_plan', 'Your plan does not include "$flag"');
    if (l.state == LicenseState.readOnly || l.state == LicenseState.notStarted) {
      throw forbidden('license_read_only', 'License expired: this hub is read-only until it is renewed');
    }
  }

  // ------------------------------------------------------------------ pairing & sessions

  /// One-time pairing code shown (with IP, port and cert fingerprint) as a QR code on the hub screen. Valid 10 minutes.
  Future<String> createPairingCode() async {
    final code = randomDigits(6);
    await db.execute('INSERT INTO pairing_codes(code_hash, expires_at) VALUES (?, ?)', [sha256Hex(code), nowIso(clock().add(const Duration(minutes: 10)))]);
    return code;
  }

  Future<Map<String, Object?>> claimPairing(String code, String name, String platform) => _tx(() async {
        final row = await db.selectOne('SELECT * FROM pairing_codes WHERE code_hash = ?', [sha256Hex(code)]);
        if (row == null || row['used_at'] != null || DateTime.parse(row['expires_at']! as String).isBefore(clock())) {
          throw unauthorized('invalid_pairing_code', 'Pairing code is invalid, used or expired');
        }
        if (!['windows', 'android'].contains(platform)) throw badRequest('bad_platform', 'platform must be windows or android');
        final l = await license();
        final paired = (await db.selectOne('SELECT count(*) AS n FROM devices WHERE revoked_at IS NULL'))!['n']! as int;
        final limit = (l.payload?['limits'] as Map?)?['devicesPerBranch'];
        // the hub itself counts as the first device; lan_hub (Professional+) is needed for any other device
        if (!l.features.contains('lan_hub')) throw forbidden('feature_not_in_plan', 'Pairing other devices needs the lan_hub feature (Professional)');
        if (limit is int && paired + 1 >= limit) throw forbidden('plan_limit', 'Device limit reached for this plan');
        await db.execute('UPDATE pairing_codes SET used_at = ? WHERE code_hash = ?', [nowIso(clock()), sha256Hex(code)]);
        final id = uuidv7();
        final token = randomToken();
        await db.execute('INSERT INTO devices(id, name, platform, token_hash, paired_at) VALUES (?,?,?,?,?)', [id, name, platform, sha256Hex(token), nowIso(clock())]);
        await _audit(Actor(deviceId: id), 'device.paired', objectType: 'device', objectId: id, after: {'name': name, 'platform': platform});
        return {'deviceId': id, 'deviceToken': token, 'branchId': config.branchId};
      });

  /// Registers the hub's own device (no code needed — it is the hub). Returns its device token.
  Future<String> registerSelf(String name, String platform) async {
    final token = randomToken();
    await db.execute('INSERT INTO devices(id, name, platform, token_hash, paired_at) VALUES (?,?,?,?,?)', [uuidv7(), name, platform, sha256Hex(token), nowIso(clock())]);
    return token;
  }

  Future<String> authenticateDevice(String? token) async {
    if (token == null || token.isEmpty) throw unauthorized('missing_device_token', 'Device token required');
    final d = await db.selectOne('SELECT id FROM devices WHERE token_hash = ? AND revoked_at IS NULL', [sha256Hex(token)]);
    if (d == null) throw unauthorized('invalid_device_token', 'Unknown or revoked device');
    return d['id']! as String;
  }

  Future<Map<String, Object?>> staffLogin(String deviceId, String userId, String pin) async {
    final u = await db.selectOne('SELECT * FROM users WHERE id = ?', [userId]);
    if (u == null || u['status'] != 'active' || u['pin_hash'] == null || !verifyArgon2(u['pin_hash']! as String, pin)) {
      throw unauthorized('invalid_pin', 'Wrong user or PIN');
    }
    final token = randomToken();
    await db.execute('INSERT INTO sessions(token_hash, user_id, device_id, created_at, expires_at) VALUES (?,?,?,?,?)',
        [sha256Hex(token), userId, deviceId, nowIso(clock()), nowIso(clock().add(const Duration(hours: 12)))]);
    final roles = (jsonDecode(u['roles_json']! as String) as List).cast<Map<String, Object?>>();
    return {'sessionToken': token, 'user': {'id': userId, 'name': u['name']}, 'permissions': permissionsFor(roles).toList()..sort()};
  }

  Future<Actor> authenticate(String? deviceToken, String? sessionToken) async {
    final deviceId = await authenticateDevice(deviceToken);
    if (sessionToken == null) return Actor(deviceId: deviceId);
    final s = await db.selectOne('SELECT * FROM sessions WHERE token_hash = ? AND device_id = ?', [sha256Hex(sessionToken), deviceId]);
    if (s == null || DateTime.parse(s['expires_at']! as String).isBefore(clock())) throw unauthorized('invalid_session', 'Session expired; sign in again');
    final u = await db.selectOne('SELECT * FROM users WHERE id = ?', [s['user_id']]);
    if (u == null || u['status'] != 'active') throw unauthorized('inactive_user', 'User is not active');
    final roles = (jsonDecode(u['roles_json']! as String) as List).cast<Map<String, Object?>>();
    return Actor(deviceId: deviceId, userId: u['id']! as String, permissions: permissionsFor(roles));
  }

  /// Owner/manager PIN approval: the approver must hold [permission] and enter their PIN.
  Future<String> _approve(String? approverUserId, String? pin, String permission) async {
    if (approverUserId == null || pin == null) throw forbidden('approval_required', 'Owner/manager PIN approval required');
    final u = await db.selectOne('SELECT * FROM users WHERE id = ? AND status = ?', [approverUserId, 'active']);
    final roles = u == null ? <Map<String, Object?>>[] : (jsonDecode(u['roles_json']! as String) as List).cast<Map<String, Object?>>();
    if (u == null || !permissionsFor(roles).contains(permission) || u['pin_hash'] == null || !verifyArgon2(u['pin_hash']! as String, pin)) {
      throw forbidden('approval_denied', 'Approval PIN is wrong or the approver lacks $permission');
    }
    return approverUserId;
  }

  // ------------------------------------------------------------------ config from the cloud

  /// Applies a /sync/pull response. The license token is verified before anything is saved.
  Future<void> applyConfig(Map<String, Object?> pull) async {
    final token = pull['licenseToken'] as String?;
    if (token != null && await _verifier.verify(token) == null) {
      throw forbidden('license_invalid', 'Cloud sent a license token that does not verify; config not applied');
    }
    List<Map<String, Object?>> rows(String k) => ((pull[k] as List?) ?? const []).cast<Map<String, Object?>>();
    int b(Object? v) => v == true ? 1 : 0;
    await db.transaction(() async {
      if (token != null) await db.setMeta('license_token', token);
      for (final r in rows('floors')) {
        await db.execute('INSERT OR REPLACE INTO floors(id, name, sort_order, deleted) VALUES (?,?,?,?)', [r['id'], r['name'], r['sortOrder'], b(r['deleted'])]);
      }
      for (final r in rows('tables')) {
        await db.execute('INSERT OR REPLACE INTO tables(id, floor_id, name, seats, layout_x, layout_y, deleted) VALUES (?,?,?,?,?,?,?)',
            [r['id'], r['floorId'], r['name'], r['seats'], r['layoutX'], r['layoutY'], b(r['deleted'])]);
      }
      for (final r in rows('taxRules')) {
        await db.execute('INSERT OR REPLACE INTO tax_rules(id, name, rate_bp, deleted) VALUES (?,?,?,?)', [r['id'], r['name'], r['rateBp'], b(r['deleted'])]);
      }
      for (final r in rows('categories')) {
        await db.execute('INSERT OR REPLACE INTO categories(id, name, sort_order, deleted) VALUES (?,?,?,?)', [r['id'], r['name'], r['sortOrder'], b(r['deleted'])]);
      }
      for (final r in rows('items')) {
        await db.execute(
          'INSERT OR REPLACE INTO items(id, category_id, name, price_paise, tax_rule_id, available, is_veg, plate_colors, deleted) VALUES (?,?,?,?,?,?,?,?,?)',
          [r['id'], r['categoryId'], r['name'], r['pricePaise'], r['taxRuleId'], b(r['available']), b(r['isVeg']), r['plateColors'] == null ? null : jsonEncode(r['plateColors']), b(r['deleted'])],
        );
      }
      for (final r in rows('users')) {
        await db.execute('INSERT OR REPLACE INTO users(id, name, status, pin_hash, roles_json) VALUES (?,?,?,?,?)',
            [r['id'], r['name'], r['status'], r['pinHash'], jsonEncode(r['roles'] ?? const [])]);
      }
      final tenant = pull['tenant'] as Map<String, Object?>?;
      if (tenant != null) await db.setMeta('tenant', jsonEncode(tenant));
      final branch = rows('branches').where((x) => x['id'] == config.branchId).firstOrNull;
      if (branch != null) await db.setMeta('branch', jsonEncode(branch));
      if (pull['cursor'] != null) await db.setMeta('config_cursor', pull['cursor'].toString());
      if (pull['menuVersion'] != null) await db.setMeta('menu_version', pull['menuVersion'].toString());
    });
    _events.add(HubEvent('menu.version_changed', {'menuVersion': pull['menuVersion']}));
  }

  // ------------------------------------------------------------------ reads

  Future<Map<String, Object?>> _order(String id) async {
    final o = await db.selectOne('SELECT * FROM orders WHERE id = ?', [id]);
    if (o == null) throw notFound('Order');
    return o;
  }

  Future<List<Map<String, Object?>>> _lines(String orderId) =>
      db.query('SELECT * FROM order_lines WHERE order_id = ? ORDER BY created_at, id', [orderId]);

  List<LineInput> _inputs(List<Map<String, Object?>> lines) => lines
      .map((l) => LineInput(
            pricePaise: l['price_snapshot_paise']! as int,
            qty: l['qty']! as int,
            taxRateBp: l['tax_rate_snapshot_bp']! as int,
            reversed: l['status'] == 'reversed',
          ))
      .toList();

  Future<Map<String, Object?>> getOrder(String id) async {
    final o = await _order(id);
    final lines = await _lines(id);
    final bill = await db.selectOne('SELECT * FROM bills WHERE order_id = ?', [id]);
    final table = o['table_id'] == null ? null : await db.selectOne('SELECT name FROM tables WHERE id = ?', [o['table_id']]);
    return {
      ...o,
      'table_name': table?['name'],
      'lines': lines,
      'totals': computeBill(_inputs(lines)).toJson(),
      'bill': bill,
    };
  }

  /// Menu for order screens: categories + available items with their current tax rate.
  Future<Map<String, Object?>> menu() async => {
        'menuVersion': await db.getMeta('menu_version'),
        'categories': await db.query('SELECT id, name, sort_order FROM categories WHERE deleted = 0 ORDER BY sort_order, name'),
        'items': [
          for (final i in await db.query(
              'SELECT i.id, i.category_id, i.name, i.price_paise, i.available, i.is_veg, i.plate_colors, t.rate_bp FROM items i JOIN tax_rules t ON t.id = i.tax_rule_id WHERE i.deleted = 0 ORDER BY i.name'))
            {...i, 'plate_colors': i['plate_colors'] == null ? null : jsonDecode(i['plate_colors']! as String)},
        ],
      };

  /// Staff tiles for the PIN login screen — names and roles only, never PIN hashes.
  Future<List<Map<String, Object?>>> staff() async => [
        for (final u in await db.query("SELECT id, name, roles_json FROM users WHERE status = 'active' ORDER BY name"))
          {'id': u['id'], 'name': u['name'], 'roles': (jsonDecode(u['roles_json']! as String) as List).map((r) => (r as Map)['role']).toList()},
      ];

  /// Branch header for receipts and the hub screen.
  Future<Map<String, Object?>> branchInfo() async => {
        'tenant': jsonDecode(await db.getMeta('tenant') ?? '{}'),
        'branch': jsonDecode(await db.getMeta('branch') ?? '{}'),
      };

  Future<Map<String, Object?>> state() async {
    final live = await db.query("SELECT * FROM orders WHERE status IN ('open','billed') ORDER BY opened_at");
    final tables = await db.query('SELECT * FROM tables WHERE deleted = 0 ORDER BY floor_id, name');
    final byTable = {for (final o in live) if (o['table_id'] != null) o['table_id']: o};
    return {
      'floors': await db.query('SELECT * FROM floors WHERE deleted = 0 ORDER BY sort_order'),
      'tables': [
        for (final t in tables)
          {...t, 'status': byTable[t['id']] == null ? 'free' : (byTable[t['id']]!['status'] == 'billed' ? 'bill_printed' : 'occupied'), 'orderId': byTable[t['id']]?['id']},
      ],
      'openOrders': live,
      'kds': await db.query("SELECT * FROM kitchen_tickets WHERE status <> 'served' ORDER BY created_at"),
    };
  }

  Future<List<Map<String, Object?>>> billsOn(DateTime day) {
    final from = DateTime.utc(day.year, day.month, day.day).subtract(const Duration(hours: 5, minutes: 30)); // IST day
    return db.query('SELECT * FROM bills WHERE created_at >= ? AND created_at < ? ORDER BY invoice_no',
        [nowIso(from), nowIso(from.add(const Duration(days: 1)))]);
  }

  Future<Map<String, Object?>> syncStatus() async {
    final rows = await db.query('SELECT status, count(*) AS n FROM sync_outbox GROUP BY status');
    final m = {for (final r in rows) r['status']: r['n']};
    return {'pending': m['pending'] ?? 0, 'pushed': m['pushed'] ?? 0, 'failed': m['failed'] ?? 0, 'lastPullAt': await db.getMeta('last_pull_at')};
  }

  // ------------------------------------------------------------------ orders

  Future<void> _history(Actor a, String orderId, String? from, String to) async {
    final id = uuidv7();
    final at = nowIso(clock());
    await db.execute('INSERT INTO order_status_history(id, order_id, from_status, to_status, actor, at) VALUES (?,?,?,?,?,?)', [id, orderId, from, to, a.id, at]);
    await _outbox('order_status', id, 'create', {'orderId': orderId, 'from': from, 'to': to, 'actor': a.id, 'at': at});
  }

  void _checkVersion(Map<String, Object?> o, int? expected) {
    if (expected != null && o['version'] != expected) {
      throw conflict('stale_version', 'Order changed on another terminal (version ${o['version']}); reload and retry');
    }
  }

  Future<Map<String, Object?>> _bump(String orderId) async {
    await db.execute('UPDATE orders SET version = version + 1, updated_at = ? WHERE id = ?', [nowIso(clock()), orderId]);
    final o = await _order(orderId);
    await _outbox('order', orderId, 'update', o);
    return o;
  }

  Future<Map<String, Object?>> openOrder(Actor a, {required String type, String? tableId, String? waiterId}) async {
    a.require('order.write');
    await requireFeature(type == 'dine_in' ? 'orders.dinein' : 'orders.takeaway');
    if (type != 'dine_in' && type != 'takeaway') throw badRequest('bad_type', 'type must be dine_in or takeaway');
    if (type == 'dine_in' && tableId == null) throw badRequest('table_required', 'Dine-in orders need a table');
    if (type == 'takeaway' && tableId != null) throw badRequest('no_table_for_takeaway', 'Takeaway orders have no table');
    return _tx(() async {
      if (tableId != null && await db.selectOne('SELECT id FROM tables WHERE id = ? AND deleted = 0', [tableId]) == null) throw notFound('Table');
      final id = uuidv7();
      final at = nowIso(clock());
      try {
        await db.execute('INSERT INTO orders(id, type, table_id, waiter_id, status, opened_by, opened_at, version, updated_at) VALUES (?,?,?,?,?,?,?,1,?)',
            [id, type, tableId, waiterId, 'open', a.id, at, at]);
      } catch (e) {
        if ('$e'.contains('UNIQUE')) throw conflict('table_occupied', 'Table already has an open order');
        rethrow;
      }
      final o = await _order(id);
      await _outbox('order', id, 'create', o);
      await _history(a, id, null, 'open');
      _raise('table.status_changed', {'tableId': tableId, 'status': 'occupied', 'orderId': id});
      return o;
    });
  }

  Future<Map<String, Object?>> addLines(Actor a, String orderId, List<Map<String, Object?>> lines, {int? version}) async {
    a.require('order.write');
    if (lines.isEmpty) throw badRequest('no_lines', 'Add at least one line');
    return _tx(() async {
      final o = await _order(orderId);
      if (o['status'] != 'open') throw conflict('order_not_open', 'Order is ${o['status']}; lines can no longer be added');
      _checkVersion(o, version);
      for (final l in lines) {
        final qty = l['qty'];
        if (qty is! int || qty <= 0) throw badRequest('bad_qty', 'qty must be a positive integer');
        final item = await db.selectOne(
            'SELECT i.*, t.rate_bp FROM items i JOIN tax_rules t ON t.id = i.tax_rule_id WHERE i.id = ? AND i.deleted = 0', [l['menuItemId']]);
        if (item == null) throw notFound('Menu item');
        if (item['available'] != 1) throw conflict('item_unavailable', '${item['name']} is not available');
        final id = uuidv7();
        // price + tax snapshots: later menu changes never alter this line
        await db.execute(
          'INSERT INTO order_lines(id, order_id, menu_item_id, name_snapshot, price_snapshot_paise, tax_rate_snapshot_bp, qty, notes, status, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)',
          [id, orderId, item['id'], item['name'], item['price_paise'], item['rate_bp'], qty, l['notes'], 'pending', nowIso(clock())],
        );
        await _outbox('order_line', id, 'create', (await db.selectOne('SELECT * FROM order_lines WHERE id = ?', [id]))!);
      }
      await _bump(orderId);
      _raise('order.updated', {'orderId': orderId});
      return getOrder(orderId);
    });
  }

  Future<Map<String, Object?>> updateLine(Actor a, String orderId, String lineId, {int? qty, String? notes, int? version}) async {
    a.require('order.write');
    return _tx(() async {
      final o = await _order(orderId);
      _checkVersion(o, version);
      final l = await db.selectOne('SELECT * FROM order_lines WHERE id = ? AND order_id = ?', [lineId, orderId]);
      if (l == null) throw notFound('Line');
      if (l['status'] != 'pending') throw conflict('line_sent', 'Sent lines cannot be edited, only reversed');
      if (qty != null && qty <= 0) throw badRequest('bad_qty', 'qty must be positive; reverse the line to remove it');
      await db.execute('UPDATE order_lines SET qty = coalesce(?, qty), notes = coalesce(?, notes) WHERE id = ?', [qty, notes, lineId]);
      await _outbox('order_line', lineId, 'update', (await db.selectOne('SELECT * FROM order_lines WHERE id = ?', [lineId]))!);
      await _bump(orderId);
      _raise('order.updated', {'orderId': orderId});
      return getOrder(orderId);
    });
  }

  /// KOT: sends pending lines to the kitchen as one ticket. Sent lines can only be reversed afterwards.
  Future<Map<String, Object?>> sendKot(Actor a, String orderId) async {
    a.require('order.write');
    return _tx(() async {
      final o = await _order(orderId);
      if (o['status'] != 'open') throw conflict('order_not_open', 'Order is ${o['status']}');
      final pending = await db.query("SELECT id FROM order_lines WHERE order_id = ? AND status = 'pending'", [orderId]);
      if (pending.isEmpty) throw conflict('nothing_to_send', 'No new lines to send');
      final at = nowIso(clock());
      await db.execute("UPDATE order_lines SET status = 'sent', sent_at = ? WHERE order_id = ? AND status = 'pending'", [at, orderId]);
      final kotNo = ((await db.selectOne('SELECT coalesce(max(kot_no), 0) + 1 AS n FROM kitchen_tickets'))!['n']! as int);
      final id = uuidv7();
      final ids = pending.map((r) => r['id']).toList();
      await db.execute('INSERT INTO kitchen_tickets(id, order_id, kot_no, line_ids_json, status, created_at) VALUES (?,?,?,?,?,?)', [id, orderId, kotNo, jsonEncode(ids), 'new', at]);
      await _outbox('kitchen_ticket', id, 'create', (await db.selectOne('SELECT * FROM kitchen_tickets WHERE id = ?', [id]))!);
      await _bump(orderId);
      _raise('kds.ticket_created', {'ticketId': id, 'orderId': orderId, 'kotNo': kotNo});
      _raise('order.updated', {'orderId': orderId});
      return {'ticketId': id, 'kotNo': kotNo, 'lineIds': ids};
    });
  }

  /// AC-05: a reason is mandatory; sent lines need order.reverse.sent or an owner/manager PIN.
  /// Before billing, totals simply drop the line. On a billed (unpaid) order the bill is recomputed and a
  /// BillAdjustment(type=reversal) records the difference. A paid bill is never edited — use an adjustment.
  Future<Map<String, Object?>> reverseLine(Actor a, String orderId, String lineId,
      {String? reason, String? approverUserId, String? approverPin}) async {
    a.require('order.reverse');
    if (!isValidReason(reason)) throw badRequest('reason_required', 'A reason is required to reverse an item');
    return _tx(() async {
      final o = await _order(orderId);
      final l = await db.selectOne('SELECT * FROM order_lines WHERE id = ? AND order_id = ?', [lineId, orderId]);
      if (l == null) throw notFound('Line');
      if (l['status'] == 'reversed') throw conflict('already_reversed', 'Line is already reversed');
      if (o['status'] == 'paid') throw conflict('bill_paid', 'Bill is paid; post a bill adjustment instead');
      if (o['status'] == 'cancelled') throw conflict('order_cancelled', 'Order is cancelled');
      String? approvedBy;
      if (l['status'] == 'sent' && !a.permissions.contains('order.reverse.sent')) {
        approvedBy = await _approve(approverUserId, approverPin, 'order.reverse.sent');
      }
      final before = await getOrder(orderId);
      final at = nowIso(clock());
      await db.execute("UPDATE order_lines SET status = 'reversed', reversed_at = ?, reversed_by = ?, reversal_reason = ?, reversal_approved_by = ? WHERE id = ?",
          [at, a.id, reason!.trim(), approvedBy, lineId]);
      final amount = (l['price_snapshot_paise']! as int) * (l['qty']! as int);
      await _outbox('order_line', lineId, 'reverse', {
        ...(await db.selectOne('SELECT * FROM order_lines WHERE id = ?', [lineId]))!,
        'amountPaise': amount,
      });
      Map<String, Object?>? adjustment;
      if (o['status'] == 'billed') {
        final bill = (await db.selectOne('SELECT * FROM bills WHERE order_id = ?', [orderId]))!;
        final newTotals = await _recomputeBill(bill);
        adjustment = await _insertAdjustment(a, bill['id']! as String, 'reversal', (newTotals['totalPaise']! as int) - (bill['total_paise']! as int), reason.trim(), approvedBy);
      }
      final remaining = await db.selectOne("SELECT count(*) AS n FROM order_lines WHERE order_id = ? AND status <> 'reversed'", [orderId]);
      if (remaining!['n'] == 0 && o['status'] == 'open') {
        await db.execute("UPDATE orders SET status = 'cancelled' WHERE id = ?", [orderId]);
        await _history(a, orderId, 'open', 'cancelled');
        _raise('table.status_changed', {'tableId': o['table_id'], 'status': 'free'});
      }
      await _bump(orderId);
      final after = await getOrder(orderId);
      await _audit(a, 'order.line_reversed', objectType: 'order_line', objectId: lineId, reason: reason.trim(),
          before: {'status': l['status'], 'orderTotalPaise': (before['totals']! as Map)['totalPaise']},
          after: {'status': 'reversed', 'amountPaise': amount, 'orderTotalPaise': (after['totals']! as Map)['totalPaise'], 'approvedBy': approvedBy});
      _raise('order.updated', {'orderId': orderId});
      return {...after, if (adjustment != null) 'adjustment': adjustment};
    });
  }

  /// AC-04: moves the whole order in one transaction. The partial unique index makes "target occupied"
  /// a hard conflict, and the version check stops two terminals racing on the same order.
  Future<Map<String, Object?>> transfer(Actor a, String orderId, String toTableId, {int? version}) async {
    a.require('order.transfer');
    await requireFeature('tables');
    return _tx(() async {
      final o = await _order(orderId);
      if (o['type'] != 'dine_in' || o['table_id'] == null) throw conflict('not_dine_in', 'Only dine-in orders sit at a table');
      if (!['open', 'billed'].contains(o['status'])) throw conflict('order_closed', 'Order is ${o['status']}');
      _checkVersion(o, version);
      if (o['table_id'] == toTableId) throw conflict('same_table', 'Order is already at that table');
      final target = await db.selectOne('SELECT * FROM tables WHERE id = ? AND deleted = 0', [toTableId]);
      if (target == null) throw notFound('Table');
      final from = o['table_id']! as String;
      try {
        final n = await db.execute('UPDATE orders SET table_id = ?, version = version + 1, updated_at = ? WHERE id = ? AND version = ?',
            [toTableId, nowIso(clock()), orderId, o['version']]);
        if (n != 1) throw conflict('stale_version', 'Order changed on another terminal; reload and retry');
      } catch (e) {
        if (e is HubError) rethrow;
        if ('$e'.contains('UNIQUE')) throw conflict('table_occupied', 'Table ${target['name']} already has an open order');
        rethrow;
      }
      final id = uuidv7();
      final at = nowIso(clock());
      await db.execute('INSERT INTO table_transfers(id, order_id, from_table_id, to_table_id, actor, at) VALUES (?,?,?,?,?,?)', [id, orderId, from, toTableId, a.id, at]);
      await _outbox('table_transfer', id, 'create', {'id': id, 'orderId': orderId, 'fromTableId': from, 'toTableId': toTableId, 'actor': a.id, 'at': at});
      await _outbox('order', orderId, 'update', await _order(orderId));
      await _audit(a, 'order.transferred', objectType: 'order', objectId: orderId, before: {'tableId': from}, after: {'tableId': toTableId});
      _raise('order.transferred', {'orderId': orderId, 'fromTableId': from, 'toTableId': toTableId});
      _raise('table.status_changed', {'tableId': from, 'status': 'free'});
      _raise('table.status_changed', {'tableId': toTableId, 'status': 'occupied', 'orderId': orderId});
      return getOrder(orderId);
    });
  }

  // ------------------------------------------------------------------ bills

  Discount _discountOf(Map<String, Object?> bill) =>
      Discount.fromJson(bill['discount_json'] == null ? null : jsonDecode(bill['discount_json']! as String) as Map<String, Object?>);

  Future<Map<String, Object?>> _recomputeBill(Map<String, Object?> bill) async {
    final lines = await _lines(bill['order_id']! as String);
    final t = computeBill(_inputs(lines), discount: _discountOf(bill), tipPaise: bill['tip_paise']! as int);
    await db.execute(
      'UPDATE bills SET subtotal_paise = ?, discount_paise = ?, cgst_paise = ?, sgst_paise = ?, round_off_paise = ?, total_paise = ? WHERE id = ?',
      [t.subtotalPaise, t.discountPaise, t.cgstPaise, t.sgstPaise, t.roundOffPaise, t.totalPaise, bill['id']],
    );
    final updated = (await db.selectOne('SELECT * FROM bills WHERE id = ?', [bill['id']]))!;
    await _outbox('bill', bill['id']! as String, 'update', updated);
    return t.toJson()..remove('lines');
  }

  Future<String> _nextInvoiceNo() async {
    final fy = financialYear(clock());
    final row = await db.selectOne('SELECT last_number FROM invoice_counters WHERE branch_code = ? AND fy = ?', [config.branchCode, fy]);
    final next = ((row?['last_number'] as int?) ?? 0) + 1;
    await db.execute(
      'INSERT INTO invoice_counters(branch_code, fy, last_number) VALUES (?,?,?) ON CONFLICT(branch_code, fy) DO UPDATE SET last_number = excluded.last_number',
      [config.branchCode, fy, next],
    );
    return formatInvoiceNo(config.branchCode, fy, next);
  }

  /// Generates the bill (totals + gap-free invoice number) and locks the order against new lines.
  Future<Map<String, Object?>> generateBill(Actor a, String orderId, {Map<String, Object?>? discount, String? discountReason}) async {
    a.require('payment.take');
    await requireFeature('billing');
    final d = Discount.fromJson(discount);
    if (d is! NoDiscount) {
      a.require('discount.apply');
      final heavy = switch (d) {
        PercentDiscount(:final bp) => bp > config.discountReasonAboveBp,
        FlatDiscount() => true, // judged against the subtotal below
        NoDiscount() => false,
      };
      if (heavy && d is PercentDiscount && !isValidReason(discountReason)) {
        throw badRequest('reason_required', 'A reason is required for discounts above ${config.discountReasonAboveBp / 100}%');
      }
    }
    return _tx(() async {
      final o = await _order(orderId);
      if (o['status'] != 'open') throw conflict('order_not_open', 'Order is ${o['status']}');
      final lines = await _lines(orderId);
      if (lines.where((l) => l['status'] != 'reversed').isEmpty) throw conflict('empty_order', 'Nothing to bill');
      final BillTotals t;
      try {
        t = computeBill(_inputs(lines), discount: d);
      } on BillingError catch (e) {
        throw badRequest(e.code, e.message);
      }
      if (d is FlatDiscount && d.paise * 10000 > t.subtotalPaise * config.discountReasonAboveBp && !isValidReason(discountReason)) {
        throw badRequest('reason_required', 'A reason is required for discounts above ${config.discountReasonAboveBp / 100}%');
      }
      final id = uuidv7();
      final invoiceNo = await _nextInvoiceNo();
      final at = nowIso(clock());
      await db.execute(
        '''INSERT INTO bills(id, order_id, invoice_no, subtotal_paise, discount_paise, cgst_paise, sgst_paise, tip_paise, round_off_paise,
           total_paise, discount_json, discount_reason, status, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
        [id, orderId, invoiceNo, t.subtotalPaise, t.discountPaise, t.cgstPaise, t.sgstPaise, 0, t.roundOffPaise, t.totalPaise,
         discount == null ? null : jsonEncode(discount), discountReason, 'open', at],
      );
      await db.execute("UPDATE orders SET status = 'billed' WHERE id = ?", [orderId]);
      await _history(a, orderId, 'open', 'billed');
      await _bump(orderId);
      final bill = (await db.selectOne('SELECT * FROM bills WHERE id = ?', [id]))!;
      await _outbox('bill', id, 'create', bill);
      if (d is! NoDiscount) {
        await _audit(a, 'bill.discount_applied', objectType: 'bill', objectId: id, after: {'discount': discount, 'discountPaise': t.discountPaise}, reason: discountReason);
      }
      _raise('bill.created', {'billId': id, 'orderId': orderId, 'invoiceNo': invoiceNo});
      _raise('table.status_changed', {'tableId': o['table_id'], 'status': 'bill_printed', 'orderId': orderId});
      return {...bill, 'lines': t.lines.map((x) => x.toJson()).toList()};
    });
  }

  Future<Map<String, Object?>> _bill(String id) async {
    final b = await db.selectOne('SELECT * FROM bills WHERE id = ?', [id]);
    if (b == null) throw notFound('Bill');
    return b;
  }

  /// AC-06: the tip goes to exactly one waiter; dine-in defaults to the order's waiter, and a dine-in tip with
  /// no waiter at all is refused so the cashier is prompted to pick one.
  Future<Map<String, Object?>> assignTip(Actor a, String billId, {required int amountPaise, String? waiterId}) async {
    a.require('payment.take');
    if (amountPaise < 0) throw badRequest('bad_tip', 'Tip cannot be negative');
    return _tx(() async {
      final bill = await _bill(billId);
      if (bill['status'] != 'open') throw conflict('bill_paid', 'Bill is already paid');
      final o = await _order(bill['order_id']! as String);
      final waiter = waiterId ?? o['waiter_id'] as String?;
      if (waiter == null) throw badRequest('waiter_required', 'Choose the waiter who receives this tip');
      final u = await db.selectOne('SELECT * FROM users WHERE id = ?', [waiter]);
      final isWaiter = u != null && (jsonDecode(u['roles_json']! as String) as List).any((r) => (r as Map)['role'] == 'waiter');
      if (!isWaiter) throw badRequest('not_a_waiter', 'Tips can only be assigned to a waiter');
      await db.execute('UPDATE bills SET tip_paise = ? WHERE id = ?', [amountPaise, billId]);
      final totals = await _recomputeBill((await _bill(billId)));
      final id = uuidv7();
      final at = nowIso(clock());
      await db.execute('DELETE FROM tip_allocations WHERE bill_id = ?', [billId]);
      await db.execute('INSERT INTO tip_allocations(id, bill_id, waiter_id, amount_paise, actor, at) VALUES (?,?,?,?,?,?)', [id, billId, waiter, amountPaise, a.id, at]);
      await _outbox('tip_allocation', id, 'create', {'id': id, 'billId': billId, 'waiterId': waiter, 'amountPaise': amountPaise, 'actor': a.id, 'at': at});
      return {'billId': billId, 'waiterId': waiter, 'tipPaise': amountPaise, 'totals': totals};
    });
  }

  Future<List<Map<String, Object?>>> tipsByWaiter() => db.query(
      'SELECT waiter_id, sum(amount_paise) AS tip_paise, count(*) AS bills FROM tip_allocations GROUP BY waiter_id ORDER BY tip_paise DESC');

  /// AC-07: every payment carries an idempotency key; a repeated key returns the first result and never charges twice.
  Future<Map<String, Object?>> addPayment(Actor a, String billId, String? idempotencyKey,
      {required String mode, int? amountPaise, int? tenderedPaise, String? reference}) async {
    a.require('payment.take');
    if (idempotencyKey == null || idempotencyKey.length < 8 || idempotencyKey.length > 128) {
      throw badRequest('idempotency_key_required', 'Idempotency-Key header (8–128 chars) is required');
    }
    final existing = await db.selectOne('SELECT response_json FROM payments WHERE idempotency_key = ?', [idempotencyKey]);
    if (existing != null) return {...jsonDecode(existing['response_json']! as String) as Map<String, Object?>, 'replayed': true};
    await requireFeature('billing');
    return _tx(() async {
      final again = await db.selectOne('SELECT response_json FROM payments WHERE idempotency_key = ?', [idempotencyKey]);
      if (again != null) return {...jsonDecode(again['response_json']! as String) as Map<String, Object?>, 'replayed': true};
      final bill = await _bill(billId);
      if (bill['status'] == 'paid') throw conflict('bill_paid', 'Bill is already fully paid');
      final paidSoFar = ((await db.selectOne('SELECT coalesce(sum(amount_paise),0) AS s FROM payments WHERE bill_id = ?', [billId]))!['s']! as int);
      final total = bill['total_paise']! as int;
      final PaymentInput input = switch (mode) {
        'cash' => PaymentInput.cash(tenderedPaise ?? (throw badRequest('tendered_required', 'Cash needs tenderedPaise'))),
        'upi' => PaymentInput.upi(amountPaise ?? (throw badRequest('amount_required', 'UPI needs amountPaise'))),
        'card' => PaymentInput.card(amountPaise ?? (throw badRequest('amount_required', 'Card needs amountPaise'))),
        _ => throw badRequest('bad_mode', 'mode must be cash, upi or card'),
      };
      final PaymentSummary s;
      try {
        s = applyPayments(total - paidSoFar, [input]);
      } on BillingError catch (e) {
        throw badRequest(e.code, e.message);
      }
      final applied = s.applied.single;
      final id = uuidv7();
      final at = nowIso(clock());
      final remaining = s.remainingPaise;
      final response = {
        'paymentId': id, 'billId': billId, 'mode': mode, 'amountPaise': applied.appliedPaise, 'tenderedPaise': tenderedPaise,
        'changePaise': applied.changePaise, 'remainingPaise': remaining, 'billStatus': remaining == 0 ? 'paid' : 'open', 'at': at,
      };
      await db.execute(
        'INSERT INTO payments(id, bill_id, mode, amount_paise, tendered_paise, change_paise, reference, idempotency_key, response_json, actor, at) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        [id, billId, mode, applied.appliedPaise, tenderedPaise, applied.changePaise, reference, idempotencyKey, jsonEncode(response), a.id, at],
      );
      await _outbox('payment', id, 'create', {...response, 'idempotencyKey': idempotencyKey, 'reference': reference});
      await _audit(a, 'payment.taken', objectType: 'bill', objectId: billId, after: {'mode': mode, 'amountPaise': applied.appliedPaise});
      if (remaining == 0) {
        await db.execute("UPDATE bills SET status = 'paid', closed_at = ? WHERE id = ?", [at, billId]);
        await _outbox('bill', billId, 'update', await _bill(billId));
        final orderId = bill['order_id']! as String;
        final o = await _order(orderId);
        await db.execute("UPDATE orders SET status = 'paid' WHERE id = ?", [orderId]);
        await _history(a, orderId, 'billed', 'paid');
        await _bump(orderId);
        _raise('bill.paid', {'billId': billId, 'orderId': orderId});
        _raise('table.status_changed', {'tableId': o['table_id'], 'status': 'free'});
      }
      return response;
    });
  }

  Future<Map<String, Object?>> _insertAdjustment(Actor a, String billId, String type, int amountPaise, String reason, String? approvedBy) async {
    final id = uuidv7();
    final at = nowIso(clock());
    await db.execute('INSERT INTO bill_adjustments(id, bill_id, type, amount_paise, reason, approved_by, actor, at) VALUES (?,?,?,?,?,?,?,?)',
        [id, billId, type, amountPaise, reason, approvedBy, a.id, at]);
    final row = (await db.selectOne('SELECT * FROM bill_adjustments WHERE id = ?', [id]))!;
    await _outbox('bill_adjustment', id, 'create', row);
    _raise('bill.adjusted', {'billId': billId, 'adjustmentId': id});
    return row;
  }

  /// Post-payment correction. The paid bill row stays untouched; the adjustment carries reason + approver.
  Future<Map<String, Object?>> addAdjustment(Actor a, String billId,
      {required int amountPaise, String? reason, String type = 'correction', String? approverUserId, String? approverPin}) async {
    if (!isValidReason(reason)) throw badRequest('reason_required', 'A reason is required');
    if (amountPaise == 0) throw badRequest('bad_amount', 'Adjustment amount cannot be zero');
    return _tx(() async {
      final bill = await _bill(billId);
      if (bill['status'] != 'paid') throw conflict('bill_not_paid', 'Only paid bills take adjustments; edit the open bill instead');
      String? approvedBy;
      if (!a.permissions.contains('bill.adjust')) approvedBy = await _approve(approverUserId, approverPin, 'bill.adjust');
      final row = await _insertAdjustment(a, billId, type, amountPaise, reason!.trim(), approvedBy ?? a.userId);
      await _audit(a, 'bill.adjusted', objectType: 'bill', objectId: billId, after: row, reason: reason.trim());
      return row;
    });
  }

  Future<void> close() async {
    await _events.close();
  }
}
