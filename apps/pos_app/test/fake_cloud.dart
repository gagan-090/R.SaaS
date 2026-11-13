import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The cloud API as the owner console inside the POS sees it: single-use rotating refresh tokens (like the real
/// /auth/refresh), the signed-in owner on /me, and empty answers for the console's pages.
class FakeCloud {
  final _valid = <String>{};
  final _access = <String>{};
  int _n = 0;
  final calls = <String>[];
  int refreshes = 0;

  /// A refresh token as /sync/console-session hands it out (through the main device).
  String issue() {
    final t = 'rt-${++_n}';
    _valid.add(t);
    return t;
  }

  /// The server forgets every session (expired, or revoked in the web console).
  void revokeAll() {
    _valid.clear();
    _access.clear();
  }

  static const me = {
    'type': 'user', 'id': 'u-own', 'email': 'owner@demo.com', 'name': 'Demo Owner', 'tenantId': 't1', 'roles': ['owner'],
    'tenant': {'id': 't1', 'code': 'R000000', 'name': 'Demo Dhaba'},
    'permissions': ['restaurant.profile.read', 'restaurant.profile.manage', 'license.read', 'staff.read', 'staff.manage', 'device.manage', 'floor.read', 'floor.manage', 'menu.read', 'menu.publish', 'reports.read'],
  };

  http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

  http.Client client() => MockClient((req) async {
        final path = req.url.path.replaceFirst('/api/v1', '');
        calls.add('${req.method} $path');
        if (req.method == 'POST' && path == '/auth/refresh') {
          refreshes++;
          final t = (jsonDecode(req.body) as Map)['refreshToken'];
          if (!_valid.remove(t)) return _json({'code': 'invalid_refresh', 'message': 'Invalid refresh token'}, 401);
          final a = 'at-${++_n}';
          _access.add(a);
          return _json({'accessToken': a, 'refreshToken': issue(), 'expiresIn': 900});
        }
        if (path.startsWith('/auth/')) return _json({'status': 'ok'});
        final bearer = (req.headers['authorization'] ?? '').replaceFirst('Bearer ', '');
        if (!_access.contains(bearer)) return _json({'code': 'unauthorized', 'message': 'Sign in again'}, 401);
        if (path == '/me') return _json(me);
        return _json({'code': 'not_found', 'message': 'Not in this fake'}, 404);
      });
}
