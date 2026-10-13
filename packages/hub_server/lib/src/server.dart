import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'hub_service.dart';
import 'util.dart';

/// HTTP + WebSocket API of the branch hub (Build Spec §09), served at /hub/v1.
/// Devices send `X-Device-Token`; staff actions also send `Authorization: Bearer <session token>`.
class HubServer {
  HubServer(this.hub, {required this.hubName, this.certFingerprint});

  final HubService hub;
  final String hubName;

  /// SHA-256 fingerprint of the hub's TLS certificate; clients pin it at pairing.
  final String? certFingerprint;
  HttpServer? _server;
  final _sockets = <WebSocketChannel>{};
  StreamSubscription<HubEvent>? _sub;

  Response _json(Object? body, [int status = 200]) =>
      Response(status, body: body == null ? null : jsonEncode(body), headers: {'content-type': 'application/json'});

  Future<Map<String, Object?>> _body(Request r) async {
    final s = await r.readAsString();
    if (s.isEmpty) return {};
    try {
      final v = jsonDecode(s);
      if (v is Map<String, Object?>) return v;
    } catch (_) {}
    throw badRequest('bad_json', 'Body must be a JSON object');
  }

  Future<Actor> _actor(Request r) {
    final auth = r.headers['authorization'];
    return hub.authenticate(r.headers['x-device-token'], auth != null && auth.startsWith('Bearer ') ? auth.substring(7) : null);
  }

  Future<Actor> _staff(Request r) async {
    final a = await _actor(r);
    if (a.userId == null) throw unauthorized('staff_login_required', 'Sign in with your PIN first');
    return a;
  }

  int? _int(Object? v) => v is int ? v : null;

  Router get router {
    final r = Router();

    r.get('/health', (Request q) => _json({'status': 'ok', 'hub': hubName, 'time': nowIso()}));

    // ---- pairing
    r.get('/pairing/info', (Request q) => _json({'hubName': hubName, 'branchId': hub.config.branchId, 'branchCode': hub.config.branchCode, 'certFingerprint': certFingerprint}));
    r.post('/pairing/claim', (Request q) async {
      final b = await _body(q);
      return _json(await hub.claimPairing('${b['code'] ?? ''}', '${b['deviceName'] ?? 'Device'}', '${b['platform'] ?? ''}'), 201);
    });

    // ---- session
    r.post('/session/login', (Request q) async {
      final deviceId = await hub.authenticateDevice(q.headers['x-device-token']);
      final b = await _body(q);
      return _json(await hub.staffLogin(deviceId, '${b['userId']}', '${b['pin']}'));
    });

    // ---- state & reads
    r.get('/staff', (Request q) async {
      await _actor(q);
      return _json(await hub.staff());
    });
    r.get('/menu', (Request q) async {
      await _actor(q);
      return _json(await hub.menu());
    });
    r.get('/branch', (Request q) async {
      await _actor(q);
      return _json(await hub.branchInfo());
    });
    r.get('/state', (Request q) async {
      await _actor(q);
      return _json(await hub.state());
    });
    r.get('/orders/<id>', (Request q, String id) async {
      (await _staff(q)).require('order.read');
      return _json(await hub.getOrder(id));
    });
    r.get('/bills', (Request q) async {
      (await _staff(q)).require('order.read');
      final d = q.url.queryParameters['date'];
      return _json(await hub.billsOn(d == null ? DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30)) : DateTime.parse(d)));
    });
    r.get('/reports/tips', (Request q) async {
      final a = await _staff(q);
      if (!a.permissions.contains('reports.read') && !a.permissions.contains('payment.take')) throw forbidden('missing_permission', 'Missing permission: reports.read');
      return _json(await hub.tipsByWaiter());
    });
    r.get('/sync/status', (Request q) async {
      await _actor(q);
      return _json(await hub.syncStatus());
    });

    // ---- orders
    r.post('/orders', (Request q) async {
      final a = await _staff(q);
      final b = await _body(q);
      return _json(await hub.openOrder(a, type: '${b['type']}', tableId: b['tableId'] as String?, waiterId: b['waiterId'] as String?), 201);
    });
    r.post('/orders/<id>/lines', (Request q, String id) async {
      final a = await _staff(q);
      final b = await _body(q);
      final lines = ((b['lines'] as List?) ?? const []).cast<Map<String, Object?>>();
      return _json(await hub.addLines(a, id, lines, version: _int(b['version'])), 201);
    });
    r.patch('/orders/<id>/lines/<lineId>', (Request q, String id, String lineId) async {
      final a = await _staff(q);
      final b = await _body(q);
      return _json(await hub.updateLine(a, id, lineId, qty: _int(b['qty']), notes: b['notes'] as String?, version: _int(b['version'])));
    });
    r.post('/orders/<id>/kot', (Request q, String id) async => _json(await hub.sendKot(await _staff(q), id), 201));
    r.post('/orders/<id>/lines/<lineId>/reverse', (Request q, String id, String lineId) async {
      final a = await _staff(q);
      final b = await _body(q);
      return _json(await hub.reverseLine(a, id, lineId,
          reason: b['reason'] as String?, approverUserId: b['approverUserId'] as String?, approverPin: b['approverPin'] as String?));
    });
    r.post('/orders/<id>/transfer', (Request q, String id) async {
      final a = await _staff(q);
      final b = await _body(q);
      return _json(await hub.transfer(a, id, '${b['toTableId']}', version: _int(b['version'])));
    });
    r.post('/orders/<id>/bill', (Request q, String id) async {
      final a = await _staff(q);
      final b = await _body(q);
      return _json(await hub.generateBill(a, id, discount: b['discount'] as Map<String, Object?>?, discountReason: b['discountReason'] as String?), 201);
    });

    // ---- bills
    r.post('/bills/<id>/payments', (Request q, String id) async {
      final a = await _staff(q);
      final b = await _body(q);
      final res = await hub.addPayment(a, id, q.headers['idempotency-key'],
          mode: '${b['mode']}', amountPaise: _int(b['amountPaise']), tenderedPaise: _int(b['tenderedPaise']), reference: b['reference'] as String?);
      return _json(res, res['replayed'] == true ? 200 : 201);
    });
    r.post('/bills/<id>/tip', (Request q, String id) async {
      final a = await _staff(q);
      final b = await _body(q);
      final amt = _int(b['amountPaise']);
      if (amt == null) throw badRequest('amount_required', 'amountPaise is required');
      return _json(await hub.assignTip(a, id, amountPaise: amt, waiterId: b['waiterId'] as String?));
    });
    r.post('/bills/<id>/adjustments', (Request q, String id) async {
      final a = await _staff(q);
      final b = await _body(q);
      final amt = _int(b['amountPaise']);
      if (amt == null) throw badRequest('amount_required', 'amountPaise is required');
      return _json(await hub.addAdjustment(a, id, amountPaise: amt, reason: b['reason'] as String?,
          approverUserId: b['approverUserId'] as String?, approverPin: b['approverPin'] as String?), 201);
    });

    // ---- events (WebSocket): state.snapshot on connect, then deltas
    r.get('/events', (Request q) async {
      await hub.authenticateDevice(q.headers['x-device-token'] ?? q.url.queryParameters['deviceToken']);
      return webSocketHandler((WebSocketChannel ch, _) async {
        _sockets.add(ch);
        ch.sink.add(jsonEncode({'type': 'state.snapshot', 'branch_id': hub.config.branchId, 'at': nowIso(), 'data': await hub.state()}));
        ch.stream.listen((_) {}, onDone: () => _sockets.remove(ch), onError: (_) => _sockets.remove(ch));
      })(q);
    });

    return r;
  }

  Middleware get _errors => (inner) => (req) async {
        try {
          return await inner(req);
        } on HubError catch (e) {
          return _json(e.toJson(), e.status);
        } on HijackException {
          rethrow; // WebSocket upgrade — shelf handles it
        } catch (e, st) {
          stderr.writeln('hub error: $e\n$st');
          return _json({'statusCode': 500, 'code': 'internal', 'message': 'Internal error'}, 500);
        }
      };

  Handler get handler {
    final root = Router()..mount('/hub/v1/', router.call);
    return const Pipeline().addMiddleware(_errors).addHandler(root.call);
  }

  /// Starts on [port] (0 = any). Pass a [SecurityContext] to serve HTTPS with the pinned self-signed cert.
  Future<HttpServer> start({InternetAddress? address, int port = 8443, SecurityContext? tls}) async {
    _sub = hub.events.listen((e) {
      final msg = jsonEncode(e.toJson(hub.config.branchId));
      for (final s in _sockets.toList()) {
        s.sink.add(msg);
      }
    });
    _server = await io.serve(handler, address ?? InternetAddress.anyIPv4, port, securityContext: tls);
    return _server!;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    for (final s in _sockets.toList()) {
      await s.sink.close();
    }
    await _server?.close(force: true);
  }
}
