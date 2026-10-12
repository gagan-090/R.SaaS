import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Serves the recorded contract fixtures (packages/contracts/fixtures) as a fake cloud API,
/// so widget tests exercise the exact JSON shapes the real API returns.
class FixtureApi {
  final calls = <http.Request>[];
  final overrides = <String, (int, Object?)>{}; // 'POST /auth/login' → (status, body)

  static final _dir = Directory('../../packages/contracts/fixtures');

  static Object? fixture(String file) => (jsonDecode(File('${_dir.path}/$file').readAsStringSync()) as Map)['response'];

  static const _routes = <(String, String, String)>[
    ('POST', r'^/auth/login$', 'POST_auth_login.mfa_required.json'),
    ('POST', r'^/auth/mfa/verify$', 'POST_auth_mfa_verify.json'),
    ('POST', r'^/auth/step-up$', 'POST_auth_step_up.json'),
    ('POST', r'^/auth/logout$', ''),
    ('GET', r'^/me$', 'GET_me.json'),
    ('GET', r'^/restaurants$', 'GET_restaurants.json'),
    ('GET', r'^/restaurants/[^/]+$', 'GET_restaurants_id.json'),
    ('POST', r'^/restaurants/[^/]+/status$', 'POST_restaurants_id_status.suspend.json'),
    ('GET', r'^/plans$', 'GET_plans.json'),
    ('GET', r'^/platform/admins$', 'GET_platform_admins.json'),
    ('GET', r'^/platform/roles$', 'GET_platform_roles.json'),
    ('POST', r'^/platform/admins/[^/]+/mfa/reset$', 'POST_platform_admins_id_mfa_reset.json'),
    ('GET', r'^/platform/audit$', 'GET_platform_audit.json'),
  ];

  http.Client client() => MockClient((req) async {
        calls.add(req);
        final path = req.url.path.replaceFirst('/api/v1', '');
        final key = '${req.method} $path';
        if (overrides.containsKey(key)) {
          final (s, b) = overrides[key]!;
          return http.Response.bytes(utf8.encode(jsonEncode(b)), s, headers: {'content-type': 'application/json'});
        }
        for (final (m, re, file) in _routes) {
          if (m == req.method && RegExp(re).hasMatch(path)) {
            if (file.isEmpty) return http.Response('', 204);
            return http.Response.bytes(utf8.encode(jsonEncode(fixture(file))), 200, headers: {'content-type': 'application/json'});
          }
        }
        return http.Response('{"code":"not_mocked","message":"$key not mocked"}', 404);
      });

  Iterable<http.Request> where(String method, String pathPart) => calls.where((c) => c.method == method && c.url.path.contains(pathPart));
}
